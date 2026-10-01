import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'forwarded_headers.dart';

/// The parsed head of one HTTP/1.x request: the request line and its headers.
typedef HttpRequestHead = ({
  String method,
  String target,
  String version,
  List<HeaderField> headers,
});

/// The parsed head of one HTTP/1.x response: the status line and its headers.
typedef HttpResponseHead = ({
  String version,
  int status,
  String reason,
  List<HeaderField> headers,
});

/// One step of an HTTP/1.x byte stream, as produced by [HttpStreamParser].
///
/// Every event carries the **raw wire bytes** it covers, so a relay can forward
/// a stream unchanged by concatenating them, or replace just a head.
sealed class HttpStreamEvent {
  /// The wire bytes this event covers.
  final Uint8List raw;

  const HttpStreamEvent(this.raw);
}

/// A complete request head (request line + headers + blank line).
final class HttpRequestHeadEvent extends HttpStreamEvent {
  /// The parsed head.
  final HttpRequestHead head;

  /// Creates a request-head event.
  const HttpRequestHeadEvent(this.head, super.raw);
}

/// A complete response head (status line + headers + blank line).
final class HttpResponseHeadEvent extends HttpStreamEvent {
  /// The parsed head.
  final HttpResponseHead head;

  /// Creates a response-head event.
  const HttpResponseHeadEvent(this.head, super.raw);
}

/// A slice of a message body, exactly as framed on the wire (for a chunked
/// body this includes the chunk-size lines and trailers).
final class HttpBodyEvent extends HttpStreamEvent {
  /// Creates a body event.
  const HttpBodyEvent(super.raw);
}

/// The message whose head was last reported is complete.
final class HttpMessageEndEvent extends HttpStreamEvent {
  /// Creates a message-end event.
  HttpMessageEndEvent() : super(Uint8List(0));
}

/// Bytes between messages that carry no message (stray CRLFs, RFC 9112 §2.2).
final class HttpGapEvent extends HttpStreamEvent {
  /// Creates a gap event.
  const HttpGapEvent(super.raw);
}

/// Bytes the parser no longer frames: everything after a protocol switch, a
/// `CONNECT`, or input it cannot parse as HTTP/1.x. Once one is emitted, every
/// later byte arrives as another [HttpPassthroughEvent].
final class HttpPassthroughEvent extends HttpStreamEvent {
  /// Creates a pass-through event.
  const HttpPassthroughEvent(super.raw);
}

/// An incremental parser for one direction of an HTTP/1.x connection.
///
/// Feed the stream through [add] in order; each call returns the events the new
/// bytes completed. Memory stays bounded: only an incomplete head (or chunk-size
/// line) is buffered, never a body, and a head larger than [maxHeadBytes] ends
/// framing.
///
/// Body framing follows RFC 9112 §6: `Transfer-Encoding: chunked` (extensions
/// and trailers included), `Content-Length`, or — for responses only — the
/// connection closing (call [close]). A **response** parser must be told the
/// method of each request it answers ([expectResponseTo]), because a `HEAD`
/// response has no body and a `CONNECT` success switches protocols; interim
/// `1xx` responses do not consume the expectation.
///
/// The parser switches to pass-through ([isPassthrough]) after a protocol
/// switch (`101`, a successful `CONNECT`, or an upgrade *request*), on an
/// ambiguous body length, on input that is not HTTP/1.x, and on an oversized
/// head.
class HttpStreamParser {
  /// Whether this parser reads responses (otherwise requests).
  final bool isResponse;

  /// The largest head (or chunk line) buffered before giving up framing.
  final int maxHeadBytes;

  final Queue<String> _expected = Queue();
  _State _state = _State.head;
  Uint8List _buf = Uint8List(0);
  int _remaining = 0;

  /// Creates a parser for client→server request bytes.
  HttpStreamParser.requests({this.maxHeadBytes = 64 * 1024})
    : isResponse = false;

  /// Creates a parser for server→client response bytes.
  HttpStreamParser.responses({this.maxHeadBytes = 64 * 1024})
    : isResponse = true;

  /// Whether the parser has stopped framing and reports raw pass-through.
  bool get isPassthrough => _state == _State.passthrough;

  /// Whether the parser is between messages (nothing partial is pending).
  bool get isIdle => _state == _State.head && _buf.isEmpty;

  /// Whether part of a head has arrived but not all of it — the window a
  /// client-header timeout measures.
  bool get isReadingHead => _state == _State.head && _buf.isNotEmpty;

  /// Records that the next unanswered request used [method] (response parsers
  /// only). Responses are matched to requests in order.
  void expectResponseTo(String method) => _expected.add(method.toUpperCase());

  /// Consumes the next [data] of the stream and returns the completed events.
  List<HttpStreamEvent> add(Uint8List data) {
    final out = <HttpStreamEvent>[];
    if (_state == _State.passthrough && _buf.isEmpty) {
      if (data.isNotEmpty) out.add(HttpPassthroughEvent(data));
      return out;
    }
    final input = _buf.isEmpty ? data : _concat(_buf, data);
    _buf = Uint8List(0);
    var pos = 0;
    while (pos < input.length) {
      switch (_state) {
        case _State.passthrough:
          out.add(HttpPassthroughEvent(Uint8List.sublistView(input, pos)));
          pos = input.length;
        case _State.head:
          var start = pos;
          while (start < input.length &&
              (input[start] == _cr || input[start] == _lf)) {
            start++;
          }
          if (start > pos) {
            out.add(HttpGapEvent(Uint8List.sublistView(input, pos, start)));
            pos = start;
            continue;
          }
          final end = _headEnd(input, pos);
          if (end < 0) {
            pos = _bufferOrPassthrough(input, pos);
            continue;
          }
          final raw = Uint8List.sublistView(input, pos, end);
          final text = latin1.decode(raw);
          if (isResponse) {
            final head = parseResponseHead(text);
            if (head == null) {
              _state = _State.passthrough;
              continue;
            }
            out.add(HttpResponseHeadEvent(head, raw));
            pos = end;
            _state = _responseFraming(head);
          } else {
            final head = parseRequestHead(text);
            if (head == null) {
              _state = _State.passthrough;
              continue;
            }
            out.add(HttpRequestHeadEvent(head, raw));
            pos = end;
            _state = _requestFraming(head);
          }
          if (_state == _State.head || _state == _State.passthrough) {
            out.add(HttpMessageEndEvent());
          }
        case _State.body:
        case _State.chunkData:
          final n = _min(_remaining, input.length - pos);
          out.add(HttpBodyEvent(Uint8List.sublistView(input, pos, pos + n)));
          pos += n;
          _remaining -= n;
          if (_remaining == 0) {
            if (_state == _State.body) {
              _state = _State.head;
              out.add(HttpMessageEndEvent());
            } else {
              _state = _State.chunkSize;
            }
          }
        case _State.closeBody:
          out.add(HttpBodyEvent(Uint8List.sublistView(input, pos)));
          pos = input.length;
        case _State.chunkSize:
        case _State.trailers:
          final nl = input.indexOf(_lf, pos);
          if (nl < 0) {
            pos = _bufferOrPassthrough(input, pos);
            continue;
          }
          final line = latin1
              .decode(Uint8List.sublistView(input, pos, nl))
              .replaceFirst(RegExp(r'\r$'), '');
          var ended = false;
          if (_state == _State.trailers) {
            if (line.isEmpty) {
              _state = _State.head;
              ended = true;
            }
          } else {
            final size = int.tryParse(line.split(';').first.trim(), radix: 16);
            if (size == null || size < 0) {
              _state = _State.passthrough;
              continue;
            }
            if (size == 0) {
              _state = _State.trailers;
            } else {
              // The chunk data plus its terminating CRLF.
              _remaining = size + 2;
              _state = _State.chunkData;
            }
          }
          out.add(HttpBodyEvent(Uint8List.sublistView(input, pos, nl + 1)));
          pos = nl + 1;
          if (ended) out.add(HttpMessageEndEvent());
      }
    }
    return out;
  }

  /// Signals the end of the stream. Completes a close-delimited response body,
  /// and reports any incomplete buffered bytes as pass-through.
  List<HttpStreamEvent> close() {
    final out = <HttpStreamEvent>[];
    if (_state == _State.closeBody) {
      _state = _State.head;
      out.add(HttpMessageEndEvent());
    }
    if (_buf.isNotEmpty) {
      out.add(HttpPassthroughEvent(_buf));
      _buf = Uint8List(0);
      _state = _State.passthrough;
    }
    return out;
  }

  int _bufferOrPassthrough(Uint8List input, int pos) {
    if (input.length - pos > maxHeadBytes) {
      _state = _State.passthrough;
      return pos;
    }
    _buf = Uint8List.fromList(Uint8List.sublistView(input, pos));
    return input.length;
  }

  _State _requestFraming(HttpRequestHead head) {
    if (head.method == 'CONNECT') return _State.passthrough;
    if (headerValue(head.headers, 'upgrade') != null &&
        headerTokens(head.headers, 'connection').contains('upgrade')) {
      return _State.passthrough;
    }
    return _bodyFraming(head.headers, closeDelimited: false);
  }

  _State _responseFraming(HttpResponseHead head) {
    final status = head.status;
    // Interim responses carry no body and do not answer the request.
    if (status >= 100 && status < 200 && status != 101) return _State.head;
    final method = _expected.isEmpty ? 'GET' : _expected.removeFirst();
    if (status == 101) return _State.passthrough;
    if (method == 'CONNECT' && status >= 200 && status < 300) {
      return _State.passthrough;
    }
    if (method == 'HEAD' || status == 204 || status == 304) return _State.head;
    return _bodyFraming(head.headers, closeDelimited: true);
  }

  _State _bodyFraming(
    List<HeaderField> headers, {
    required bool closeDelimited,
  }) {
    final te = headerTokens(headers, 'transfer-encoding');
    if (te.isNotEmpty) {
      if (te.last == 'chunked') return _State.chunkSize;
      return closeDelimited ? _State.closeBody : _State.passthrough;
    }
    final cl = headerTokens(headers, 'content-length').toSet();
    if (cl.isEmpty) return closeDelimited ? _State.closeBody : _State.head;
    final length = cl.length == 1 ? int.tryParse(cl.single) : null;
    if (length == null || length < 0) return _State.passthrough;
    if (length == 0) return _State.head;
    _remaining = length;
    return _State.body;
  }

  static final _token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final _version = RegExp(r'^HTTP/(1\.[01])$');
  static final _statusLine = RegExp(r'^HTTP/(1\.[01]) (\d{3})(?: (.*))?$');

  /// Parses a request head, or `null` when it is not well-formed HTTP/1.x.
  static HttpRequestHead? parseRequestHead(String text) {
    final lines = _lines(text);
    if (lines.isEmpty) return null;
    final requestLine = lines.first.split(' ');
    if (requestLine.length != 3) return null;
    final [method, target, versionText] = requestLine;
    final version = _version.firstMatch(versionText)?.group(1);
    if (!_token.hasMatch(method) || target.isEmpty || version == null) {
      return null;
    }
    final headers = _parseFields(lines.skip(1));
    if (headers == null) return null;
    return (method: method, target: target, version: version, headers: headers);
  }

  /// Parses a response head, or `null` when it is not well-formed HTTP/1.x.
  static HttpResponseHead? parseResponseHead(String text) {
    final lines = _lines(text);
    if (lines.isEmpty) return null;
    final m = _statusLine.firstMatch(lines.first);
    if (m == null) return null;
    final headers = _parseFields(lines.skip(1));
    if (headers == null) return null;
    return (
      version: m.group(1)!,
      status: int.parse(m.group(2)!),
      reason: m.group(3) ?? '',
      headers: headers,
    );
  }

  static List<String> _lines(String text) => [
    for (final l in text.split('\n')) l.replaceFirst(RegExp(r'\r$'), ''),
  ];

  static List<HeaderField>? _parseFields(Iterable<String> lines) {
    final headers = <HeaderField>[];
    for (final line in lines) {
      if (line.isEmpty) break;
      if (line.startsWith(' ') || line.startsWith('\t')) {
        // Obsolete line folding: continue the previous field's value.
        if (headers.isEmpty) return null;
        final last = headers.removeLast();
        headers.add((name: last.name, value: '${last.value} ${line.trim()}'));
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) return null;
      final name = line.substring(0, colon);
      if (!_token.hasMatch(name)) return null;
      headers.add((name: name, value: line.substring(colon + 1).trim()));
    }
    return headers;
  }

  static int _headEnd(Uint8List b, int from) {
    for (var i = from; i < b.length; i++) {
      if (b[i] != _lf) continue;
      if (i + 1 < b.length && b[i + 1] == _lf) return i + 2;
      if (i + 2 < b.length && b[i + 1] == _cr && b[i + 2] == _lf) return i + 3;
    }
    return -1;
  }

  static Uint8List _concat(Uint8List a, Uint8List b) =>
      (BytesBuilder(copy: false)
            ..add(a)
            ..add(b))
          .takeBytes();

  static int _min(int a, int b) => a < b ? a : b;

  static const int _cr = 0x0D;
  static const int _lf = 0x0A;
}

enum _State {
  head,
  body,
  closeBody,
  chunkSize,
  chunkData,
  trailers,
  passthrough,
}

/// All values of header [name] (case-insensitive) joined with `,`, or `null`
/// when absent.
String? headerValue(List<HeaderField> headers, String name) {
  final lower = name.toLowerCase();
  final all = [
    for (final h in headers)
      if (h.name.toLowerCase() == lower) h.value,
  ];
  return all.isEmpty ? null : all.join(',');
}

/// The comma-separated, trimmed, lower-cased tokens of header [name].
List<String> headerTokens(List<HeaderField> headers, String name) {
  final v = headerValue(headers, name);
  if (v == null) return const [];
  return [
    for (final t in v.split(','))
      if (t.trim().isNotEmpty) t.trim().toLowerCase(),
  ];
}

/// Encodes a request head (request line, [HttpRequestHead.headers], blank line)
/// as Latin-1 wire bytes; characters wider than Latin-1 become `?`.
Uint8List encodeHttpRequestHead(HttpRequestHead head) => _encodeHead(
  '${head.method} ${head.target} HTTP/${head.version}',
  head.headers,
);

/// Encodes a response head (status line, [HttpResponseHead.headers], blank
/// line) as Latin-1 wire bytes; characters wider than Latin-1 become `?`.
Uint8List encodeHttpResponseHead(HttpResponseHead head) => _encodeHead(
  'HTTP/${head.version} ${head.status}'
  '${head.reason.isEmpty ? '' : ' ${head.reason}'}',
  head.headers,
);

Uint8List _encodeHead(String startLine, List<HeaderField> headers) {
  final sb = StringBuffer('$startLine\r\n');
  for (final h in headers) {
    sb.write('${h.name}: ${h.value}\r\n');
  }
  sb.write('\r\n');
  return Uint8List.fromList([
    for (final c in sb.toString().codeUnits) c > 0xFF ? 0x3F : c,
  ]);
}
