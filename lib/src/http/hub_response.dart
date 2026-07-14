import 'dart:async';
import 'dart:convert';

import '../shared/errors/hub_exception.dart';

/// A protocol-agnostic outbound response.
///
/// Services return these; the transport serialises them onto the wire. The body
/// is a byte stream so large or streamed payloads (e.g. proxied responses) flow
/// without buffering. Convenience factories cover the common text/JSON/bytes
/// cases.
class HubResponse {
  /// The HTTP status code.
  final int statusCode;

  /// Response headers, with lower-cased keys.
  final Map<String, String> headers;

  /// Whether the transport may buffer this body before writing it to the socket.
  ///
  /// `true` (the default) matches `dart:io`'s own behaviour: bytes are held
  /// until an 8 KiB buffer fills or the response closes. That is right for an
  /// ordinary response and fatal for a live one — a small Server-Sent Event
  /// would sit in the buffer and never reach the client. Set it `false` for SSE
  /// or any long-lived push stream, so each chunk is flushed as it is produced.
  final bool bufferOutput;

  final Stream<List<int>> _body;
  bool _bodyRead = false;

  /// Creates a response with an explicit [statusCode], [headers] and byte
  /// [body] stream.
  HubResponse({
    required this.statusCode,
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    this.bufferOutput = true,
  }) : headers = Map.unmodifiable({
         for (final e in headers.entries) e.key.toLowerCase(): e.value,
       }),
       _body = body ?? const Stream<List<int>>.empty();

  /// A `text/plain; charset=utf-8` response.
  factory HubResponse.text(
    String body, {
    int statusCode = 200,
    Map<String, String> headers = const {},
  }) => HubResponse(
    statusCode: statusCode,
    headers: {'content-type': 'text/plain; charset=utf-8', ...headers},
    body: _single(utf8.encode(body)),
  );

  /// A `application/json; charset=utf-8` response encoding [data].
  factory HubResponse.json(
    Object? data, {
    int statusCode = 200,
    Map<String, String> headers = const {},
  }) => HubResponse(
    statusCode: statusCode,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
    body: _single(utf8.encode(jsonEncode(data))),
  );

  /// A binary response with [contentType] (defaults to octet-stream).
  factory HubResponse.bytes(
    List<int> body, {
    int statusCode = 200,
    String contentType = 'application/octet-stream',
    Map<String, String> headers = const {},
  }) => HubResponse(
    statusCode: statusCode,
    headers: {'content-type': contentType, ...headers},
    body: _single(body),
  );

  /// A streamed response, forwarding [body] without buffering it in memory.
  ///
  /// [bufferOutput] still governs whether the *transport* may coalesce chunks
  /// before writing them to the socket; pass `false` for a long-lived push
  /// stream whose chunks must reach the client as they are produced.
  factory HubResponse.stream(
    Stream<List<int>> body, {
    int statusCode = 200,
    Map<String, String> headers = const {},
    bool bufferOutput = true,
  }) => HubResponse(
    statusCode: statusCode,
    headers: headers,
    body: body,
    bufferOutput: bufferOutput,
  );

  /// A Server-Sent Events response (`text/event-stream`) carrying an already
  /// encoded SSE byte stream — see `sseResponse` for the typed [SseEvent] form.
  ///
  /// Sets [bufferOutput] `false` so every event is flushed as it is produced,
  /// and `x-accel-buffering: no` so an nginx in front of the hub does not
  /// re-introduce the same buffering. [headers] override the defaults.
  factory HubResponse.eventStream(
    Stream<List<int>> body, {
    int statusCode = 200,
    Map<String, String> headers = const {},
  }) => HubResponse(
    statusCode: statusCode,
    headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
      'x-accel-buffering': 'no',
      ...headers,
    },
    body: body,
    bufferOutput: false,
  );

  /// A convenience `200`/`204` response: `null` → empty `204`, [String] →
  /// text, other → JSON.
  factory HubResponse.ok([Object? body]) {
    if (body == null) return HubResponse(statusCode: 204);
    if (body is String) return HubResponse.text(body);
    if (body is List<int>) return HubResponse.bytes(body);
    return HubResponse.json(body);
  }

  /// A `404` text response.
  factory HubResponse.notFound([String message = 'Not Found']) =>
      HubResponse.text(message, statusCode: 404);

  /// Renders a [HubException] as a JSON error envelope
  /// (`{"error": {"code", "message"}}`) with the exception's status code.
  factory HubResponse.error(HubException e) => HubResponse.json({
    'error': {'code': e.code, 'message': e.message},
  }, statusCode: e.statusCode);

  /// A copy of this response with [headers] merged over its own — a key present
  /// in both takes the new value — preserving the status code, [bufferOutput]
  /// and the still-unread body.
  ///
  /// This is the seam middleware needs, [headers] being unmodifiable. It
  /// *consumes* this response: the copy owns the body stream, so reading the
  /// original afterwards throws, exactly as a second [read] would. Middleware
  /// calls it before reading the body, so that costs nothing.
  HubResponse withHeaders(Map<String, String> headers) => HubResponse(
    statusCode: statusCode,
    headers: {...this.headers, ...headers},
    body: read(),
    // Load-bearing: without it, wrapping an SSE response (say, in CORS
    // middleware) would silently re-buffer it and strand its events.
    bufferOutput: bufferOutput,
  );

  /// The response body as a byte stream. May only be consumed once.
  Stream<List<int>> read() {
    if (_bodyRead) {
      throw StateError('HubResponse body has already been read');
    }
    _bodyRead = true;
    return _body;
  }

  /// Buffers and returns the entire body as bytes.
  Future<List<int>> readBytes() async {
    final chunks = <int>[];
    await for (final chunk in read()) {
      chunks.addAll(chunk);
    }
    return chunks;
  }

  /// Buffers and decodes the entire body as a string ([utf8] default).
  Future<String> readAsString([Encoding encoding = utf8]) async =>
      encoding.decode(await readBytes());

  static Stream<List<int>> _single(List<int> bytes) =>
      Stream<List<int>>.value(bytes);

  @override
  String toString() => 'HubResponse($statusCode)';
}
