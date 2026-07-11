import 'dart:async';
import 'dart:convert';

import '../core/principal.dart';
import '../core/transport_protocol.dart';

/// A protocol-agnostic inbound request.
///
/// Wraps the essentials of an HTTP request (or a WebSocket upgrade request)
/// without exposing the underlying `shelf`/`dart:io` types, so services and
/// routing rules never depend on a particular server implementation. Transports
/// build these; the pipeline enriches them (e.g. attaching a [principal]); the
/// router matches on them; services consume them.
class HubRequest {
  /// The HTTP method, upper-cased (`GET`, `POST`, ...).
  final String method;

  /// The full requested URI, including scheme, host and query.
  final Uri uri;

  /// The protocol this request arrived on.
  final TransportProtocol protocol;

  /// Request headers, with lower-cased keys.
  final Map<String, String> headers;

  /// The remote peer address, if known (e.g. `203.0.113.4`).
  final String? remoteAddress;

  /// The authenticated identity, or `null` if anonymous. Set by the
  /// authentication stage of the pipeline.
  Principal? principal;

  /// A scratch space for middleware/services to stash per-request data.
  final Map<String, Object?> context = {};

  final Stream<List<int>> _body;
  bool _bodyRead = false;

  /// Creates a request. [headers] keys are lower-cased. [body] defaults to an
  /// empty stream.
  HubRequest({
    required String method,
    required this.uri,
    required this.protocol,
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    this.remoteAddress,
    this.principal,
  }) : method = method.toUpperCase(),
       headers = Map.unmodifiable({
         for (final e in headers.entries) e.key.toLowerCase(): e.value,
       }),
       _body = body ?? const Stream<List<int>>.empty();

  /// The request path (no query string).
  String get path => uri.path;

  /// The host component of the URI (no port).
  String get host => uri.host;

  /// Whether the request arrived over TLS.
  bool get isSecure => protocol.isSecure;

  /// The value of header [name] (case-insensitive), or `null`.
  String? header(String name) => headers[name.toLowerCase()];

  /// Whether this is a WebSocket upgrade request (`Upgrade: websocket`).
  bool get isWebSocketUpgrade {
    final upgrade = headers['upgrade']?.toLowerCase();
    final connection = headers['connection']?.toLowerCase();
    return upgrade == 'websocket' && (connection?.contains('upgrade') ?? false);
  }

  /// The request body as a byte stream. May only be consumed once.
  Stream<List<int>> read() {
    if (_bodyRead) {
      throw StateError('HubRequest body has already been read');
    }
    _bodyRead = true;
    return _body;
  }

  /// Buffers and returns the entire request body as bytes.
  Future<List<int>> readBytes() async {
    final chunks = <int>[];
    await for (final chunk in read()) {
      chunks.addAll(chunk);
    }
    return chunks;
  }

  /// Buffers and decodes the entire request body as a string ([utf8] default).
  Future<String> readAsString([Encoding encoding = utf8]) async =>
      encoding.decode(await readBytes());

  @override
  String toString() => 'HubRequest($method ${uri.path}, ${protocol.name})';
}
