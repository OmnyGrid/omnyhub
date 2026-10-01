import 'dart:typed_data';

import 'forwarded_headers.dart';
import 'http_stream_parser.dart';

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
/// its concern and should be relayed unchanged. Built on [HttpStreamParser].
class HttpRequestHeaderRewriter {
  /// Rewrites one request's headers; e.g. `ForwardedHeaders.apply`.
  final List<HeaderField> Function(HttpRequestHead head) rewrite;

  /// The largest request head (or chunk line) buffered before giving up and
  /// passing the stream through.
  final int maxHeadBytes;

  final HttpStreamParser _parser;

  /// Creates a rewriter applying [rewrite] to each request head.
  HttpRequestHeaderRewriter(this.rewrite, {this.maxHeadBytes = 64 * 1024})
    : _parser = HttpStreamParser.requests(maxHeadBytes: maxHeadBytes);

  /// Whether the rewriter has stopped framing and forwards bytes untouched.
  bool get isPassthrough => _parser.isPassthrough;

  /// Consumes the next [data] of the stream and returns the bytes to forward.
  Uint8List add(Uint8List data) {
    final events = _parser.add(data);
    if (events.length == 1 && events.single is HttpPassthroughEvent) {
      return events.single.raw;
    }
    final out = BytesBuilder(copy: false);
    for (final e in events) {
      switch (e) {
        case HttpRequestHeadEvent(:final head):
          out.add(
            encodeHttpRequestHead((
              method: head.method,
              target: head.target,
              version: head.version,
              headers: rewrite(head),
            )),
          );
        case HttpMessageEndEvent():
          break;
        default:
          out.add(e.raw);
      }
    }
    return out.takeBytes();
  }
}
