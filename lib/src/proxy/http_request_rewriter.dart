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

/// Rewrites the headers of every request on a raw HTTP/1.x client→server byte
/// stream, leaving bodies and everything else byte-for-byte intact.
///
/// Feed the stream through [add] in order; each call returns the bytes to
/// forward (possibly empty while a request head is still incomplete). The
/// rewriter follows the stream's framing so keep-alive connections get every
/// request rewritten, not just the first: a body is skipped by its
/// `Content-Length`, or chunk by chunk (trailers included) when it is
/// `Transfer-Encoding: chunked`.
///
/// The rewriter switches to **pass-through** — forwarding the rest of the
/// stream untouched — whenever it can no longer frame requests safely:
///
/// - after a protocol switch (`Upgrade` + `Connection: upgrade`, e.g. a
///   WebSocket handshake) or a `CONNECT`, whose following bytes are not HTTP;
/// - on a body delimited only by connection close (a non-chunked
///   `Transfer-Encoding`), or conflicting/invalid `Content-Length`s;
/// - on anything that does not parse as HTTP/1.x (including HTTP/2 prior
///   knowledge), or a head larger than [maxHeadBytes].
///
/// It never buffers more than one request head (or chunk-size line), so memory
/// stays bounded regardless of body sizes. Responses (server→client) are not
/// its concern and should be relayed unchanged.
class HttpRequestHeaderRewriter {
  /// Rewrites one request's headers; e.g. `ForwardedHeaders.apply`.
  final List<HeaderField> Function(HttpRequestHead head) rewrite;

  /// The largest request head (or chunk line) buffered before giving up and
  /// passing the stream through.
  final int maxHeadBytes;

  _State _state = _State.head;
  Uint8List _buf = Uint8List(0);
  int _remaining = 0;

  /// Creates a rewriter applying [rewrite] to each request head.
  HttpRequestHeaderRewriter(this.rewrite, {this.maxHeadBytes = 64 * 1024});

  /// Whether the rewriter has stopped framing and forwards bytes untouched.
  bool get isPassthrough => _state == _State.passthrough;

  /// Consumes the next [data] of the stream and returns the bytes to forward.
  Uint8List add(Uint8List data) {
    if (_state == _State.passthrough && _buf.isEmpty) return data;
    final input = _buf.isEmpty ? data : _concat(_buf, data);
    _buf = Uint8List(0);
    final out = BytesBuilder(copy: false);
    var pos = 0;
    while (pos < input.length) {
      switch (_state) {
        case _State.passthrough:
          out.add(Uint8List.sublistView(input, pos));
          pos = input.length;
        case _State.head:
          // Tolerate stray CRLFs between requests (RFC 9112 §2.2).
          var start = pos;
          while (start < input.length &&
              (input[start] == _cr || input[start] == _lf)) {
            start++;
          }
          if (start > pos) {
            out.add(Uint8List.sublistView(input, pos, start));
            pos = start;
            continue;
          }
          final end = _headEnd(input, pos);
          if (end < 0) {
            pos = _bufferOrPassthrough(input, pos, out);
            continue;
          }
          final head = _parseHead(
            latin1.decode(Uint8List.sublistView(input, pos, end)),
          );
          if (head == null) {
            _state = _State.passthrough;
            continue;
          }
          out.add(_serialize(head, rewrite(head)));
          pos = end;
          _state = _framing(head);
        case _State.body:
        case _State.chunkData:
          final n = _min(_remaining, input.length - pos);
          out.add(Uint8List.sublistView(input, pos, pos + n));
          pos += n;
          _remaining -= n;
          if (_remaining == 0) {
            _state = _state == _State.body ? _State.head : _State.chunkSize;
          }
        case _State.chunkSize:
        case _State.trailers:
          final nl = input.indexOf(_lf, pos);
          if (nl < 0) {
            pos = _bufferOrPassthrough(input, pos, out);
            continue;
          }
          final line = latin1
              .decode(Uint8List.sublistView(input, pos, nl))
              .replaceFirst(RegExp(r'\r$'), '');
          if (_state == _State.trailers) {
            if (line.isEmpty) _state = _State.head;
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
          out.add(Uint8List.sublistView(input, pos, nl + 1));
          pos = nl + 1;
      }
    }
    return out.takeBytes();
  }

  /// Keeps an incomplete head/line for the next [add], or gives up framing when
  /// it has outgrown [maxHeadBytes]. Returns the new read position.
  int _bufferOrPassthrough(Uint8List input, int pos, BytesBuilder out) {
    if (input.length - pos > maxHeadBytes) {
      _state = _State.passthrough;
      return pos;
    }
    _buf = Uint8List.fromList(Uint8List.sublistView(input, pos));
    return input.length;
  }

  /// The state after [head], from its original (un-rewritten) framing headers.
  _State _framing(HttpRequestHead head) {
    String? values(String name) {
      final all = [
        for (final h in head.headers)
          if (h.name.toLowerCase() == name) h.value,
      ];
      return all.isEmpty ? null : all.join(',');
    }

    List<String> tokens(String? v) => v == null
        ? const []
        : [
            for (final t in v.split(','))
              if (t.trim().isNotEmpty) t.trim().toLowerCase(),
          ];

    if (head.method == 'CONNECT') return _State.passthrough;
    if (values('upgrade') != null &&
        tokens(values('connection')).contains('upgrade')) {
      return _State.passthrough;
    }
    final te = tokens(values('transfer-encoding'));
    if (te.isNotEmpty) {
      return te.last == 'chunked' ? _State.chunkSize : _State.passthrough;
    }
    final cl = tokens(values('content-length')).toSet();
    if (cl.isEmpty) return _State.head;
    final length = cl.length == 1 ? int.tryParse(cl.single) : null;
    if (length == null || length < 0) return _State.passthrough;
    if (length == 0) return _State.head;
    _remaining = length;
    return _State.body;
  }

  static final _method = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final _version = RegExp(r'^HTTP/(1\.[01])$');

  /// Parses a request head (request line + header lines), or `null` when it is
  /// not a well-formed HTTP/1.x request.
  static HttpRequestHead? _parseHead(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'\r$'), ''));
    final it = lines.iterator;
    if (!it.moveNext()) return null;
    final requestLine = it.current.split(' ');
    if (requestLine.length != 3) return null;
    final [method, target, versionText] = requestLine;
    final version = _version.firstMatch(versionText)?.group(1);
    if (!_method.hasMatch(method) || target.isEmpty || version == null) {
      return null;
    }
    final headers = <HeaderField>[];
    while (it.moveNext()) {
      final line = it.current;
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
      if (!_method.hasMatch(name)) return null;
      headers.add((name: name, value: line.substring(colon + 1).trim()));
    }
    return (method: method, target: target, version: version, headers: headers);
  }

  static Uint8List _serialize(HttpRequestHead head, List<HeaderField> headers) {
    final sb = StringBuffer(
      '${head.method} ${head.target} HTTP/${head.version}\r\n',
    );
    for (final h in headers) {
      sb.write('${h.name}: ${h.value}\r\n');
    }
    sb.write('\r\n');
    // Header bytes are Latin-1 on the wire; anything wider becomes '?'.
    return Uint8List.fromList([
      for (final c in sb.toString().codeUnits) c > 0xFF ? 0x3F : c,
    ]);
  }

  /// The index just past the blank line ending the head starting at [from], or
  /// -1 when the head is not complete yet. Accepts CRLF or bare LF endings.
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

enum _State { head, body, chunkSize, chunkData, trailers, passthrough }
