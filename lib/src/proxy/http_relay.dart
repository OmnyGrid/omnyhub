import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'cache/cache_control.dart';
import 'cache/http_cache.dart';
import 'forwarded_headers.dart';
import 'http_stream_parser.dart';

/// The time limits an [HttpRelay] enforces. A `null` or zero duration turns a
/// limit off.
@immutable
class HttpRelayTimeouts {
  /// From a request being fully sent to its response head being complete. On
  /// expiry the client gets `504 Gateway Timeout` and the connection closes.
  final Duration? responseHeader;

  /// The longest silence between response bytes once a response has started.
  /// On expiry the connection closes (the status is already on the wire).
  final Duration? idle;

  /// From the first byte of a request head to its end; idle keep-alive time
  /// between requests is not counted. On expiry the client gets `408 Request
  /// Timeout` and the connection closes.
  final Duration? clientHeader;

  /// A cap on a whole exchange, from the request being sent to the response
  /// ending: `504` if no response byte was sent yet, otherwise a close.
  final Duration? maxDuration;

  /// Creates timeouts; the defaults are 60s / 5m / 60s / off.
  const HttpRelayTimeouts({
    this.responseHeader = const Duration(seconds: 60),
    this.idle = const Duration(minutes: 5),
    this.clientHeader = const Duration(seconds: 60),
    this.maxDuration,
  });

  /// No limits at all.
  static const HttpRelayTimeouts none = HttpRelayTimeouts(
    responseHeader: null,
    idle: null,
    clientHeader: null,
  );
}

/// Starts a one-shot timer; injectable for tests.
typedef RelayTimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// An HTTP/1.x relay for one client connection over a raw byte stream — the
/// shape of a TCP tunnel carrying HTTP — adding optional caching and timeouts.
///
/// Feed client bytes to [addFromClient] and origin bytes to [addFromUpstream]
/// (and [closeUpstream] when the origin closes). The relay calls [toUpstream]
/// with what the origin must see, [toClient] with what the client must see,
/// and [closeConnection] when the connection must end (after its final bytes
/// were handed to [toClient]). Call [dispose] when the connection ends for any
/// other reason.
///
/// Requests are rewritten by [rewriteRequest] (e.g. forwarding headers). With a
/// [cache] each request is a **hit** (answered by the relay; the origin never
/// sees it), a **revalidate** (the origin is asked with the entry's
/// validators; a `304` refreshes it), a **miss** (forwarded; a storable
/// response is captured as it streams and stored when complete) or a
/// **bypass**. Each response then carries `[cacheStatusHeader]: HIT | MISS |
/// REVALIDATED | BYPASS | STALE`, and served entries an `Age`. A successful
/// unsafe request invalidates its target and `Location` / `Content-Location`.
///
/// Failures follow common reverse-proxy behaviour ([HttpRelayTimeouts]): no
/// response head in time → `504`; the origin closing before responding →
/// `502`; a stalled or over-long response that already started → close; a
/// client that never finishes its request head → `408`. With a cache, a stale
/// entry allowed by `stale-if-error` replaces a `502`/`504`. After any such
/// failure the connection closes, because a late origin response would
/// otherwise answer the wrong request.
///
/// Responses reach the client in request order, as keep-alive requires, even
/// when a hit is ready before an earlier miss has finished. After a protocol
/// switch (WebSocket) or unparseable input, bytes pass through untouched and
/// no timeouts apply.
class HttpRelay {
  /// The cache consulted and filled, or `null` for none.
  final HttpCache? cache;

  /// The time limits.
  final HttpRelayTimeouts timeouts;

  /// Receives bytes for the origin.
  final void Function(Uint8List bytes) toUpstream;

  /// Receives bytes for the client.
  final void Function(Uint8List bytes) toClient;

  /// Called once when the relay needs the connection closed.
  final void Function() closeConnection;

  /// Rewrites each forwarded request's headers (e.g. `ForwardedHeaders.apply`).
  final List<HeaderField> Function(HttpRequestHead head)? rewriteRequest;

  /// The response header reporting the cache outcome (only with a [cache]).
  final String cacheStatusHeader;

  final RelayTimerFactory _timer;
  final DateTime Function() _now;

  final HttpStreamParser _requests = HttpStreamParser.requests();
  final HttpStreamParser _responses = HttpStreamParser.responses();
  final Queue<_Exchange> _queue = Queue();
  final Queue<_Exchange> _awaiting = Queue();
  _Exchange? _receiving;
  Timer? _clientTimer;

  /// Set once the connection is ending: client input is ignored and the
  /// connection closes when the queue drains.
  bool _closing = false;
  bool _ignoreUpstream = false;
  bool _closed = false;

  /// Creates a relay.
  HttpRelay({
    required this.toUpstream,
    required this.toClient,
    required this.closeConnection,
    this.cache,
    this.timeouts = const HttpRelayTimeouts(),
    this.rewriteRequest,
    this.cacheStatusHeader = 'X-Cache',
    RelayTimerFactory? timer,
    DateTime Function()? now,
  }) : _timer = timer ?? Timer.new,
       _now = now ?? cache?.now ?? DateTime.now;

  /// Whether [closeConnection] has been called (or [dispose]d).
  bool get isClosed => _closed;

  /// Feeds the next client→origin bytes.
  void addFromClient(Uint8List data) {
    if (_closing || _closed) return;
    for (final e in _requests.add(data)) {
      switch (e) {
        case HttpRequestHeadEvent(:final head):
          _onRequest(head);
        case HttpBodyEvent():
          if (_receiving != null) toUpstream(e.raw);
        case HttpMessageEndEvent():
          final ex = _receiving;
          _receiving = null;
          if (ex != null) _requestSent(ex);
        case HttpGapEvent():
          break;
        case HttpPassthroughEvent():
          _cancelAllTimers();
          toUpstream(e.raw);
        case HttpResponseHeadEvent():
          break;
      }
    }
    _syncClientTimer();
  }

  /// Feeds the next origin→client bytes.
  void addFromUpstream(Uint8List data) {
    if (_ignoreUpstream || _closed) return;
    _onResponseEvents(_responses.add(data));
  }

  /// Signals the origin closed its side. A response in progress ends (if it
  /// was close-delimited) or is cut off; a request still waiting for its
  /// response gets `502 Bad Gateway`.
  void closeUpstream() {
    if (_ignoreUpstream || _closed) return;
    _onResponseEvents(_responses.close());
    _ignoreUpstream = true;
    final ex = _awaiting.firstOrNull;
    if (ex == null) {
      _closing = true;
      _drain();
    } else if (ex.finalHeadSent) {
      _abort();
    } else {
      _fail(ex, 502, 'Bad Gateway');
    }
  }

  /// Cancels every timer; call when the connection ends.
  void dispose() {
    _closed = true;
    _cancelAllTimers();
  }

  // --- Requests -------------------------------------------------------------

  void _onRequest(HttpRequestHead head) {
    final ex = _Exchange(head);
    _queue.add(ex);
    final c = cache;
    if (c == null) {
      _forward(ex, _rewritten(head));
      return;
    }
    switch (c.lookup(head, at: _now())) {
      case CacheHit(:final entry):
        c.recordHit();
        ex
          ..out.add(_serve(entry, head, 'HIT'))
          ..done = true;
        _drain();
      case CacheUnsatisfiable():
        c.recordMiss();
        ex
          ..out.add(_errorResponse(head, 504, 'Gateway Timeout', 'MISS'))
          ..done = true;
        _drain();
      case CacheRevalidate(:final entry):
        ex
          ..revalidating = entry
          ..store = true
          ..status = 'MISS';
        _forward(ex, _conditional(_rewritten(head), entry));
      case CacheMiss(:final stale):
        c.recordMiss();
        ex
          ..store = true
          ..stale = stale
          ..status = 'MISS';
        _forward(ex, _rewritten(head));
      case CacheBypass():
        c.recordBypass();
        ex.status = 'BYPASS';
        _forward(ex, _rewritten(head));
    }
  }

  List<HeaderField> _rewritten(HttpRequestHead head) =>
      rewriteRequest?.call(head) ?? head.headers;

  void _forward(_Exchange ex, List<HeaderField> headers) {
    ex.requestTime = _now();
    _awaiting.add(ex);
    _receiving = ex;
    _responses.expectResponseTo(ex.request.method);
    toUpstream(
      encodeHttpRequestHead((
        method: ex.request.method,
        target: ex.request.target,
        version: ex.request.version,
        headers: headers,
      )),
    );
  }

  /// The request (body included) is fully sent: start its timers.
  void _requestSent(_Exchange ex) {
    ex.requestSent = true;
    final max = _limit(timeouts.maxDuration);
    if (max != null && !ex.done) {
      ex.maxTimer = _timer(max, () => _onMaxDuration(ex));
    }
    _armHeaderTimer();
  }

  static List<HeaderField> _conditional(
    List<HeaderField> headers,
    HttpCacheEntry entry,
  ) {
    const drop = {'if-none-match', 'if-modified-since'};
    final etag = headerValue(entry.head.headers, 'etag');
    final lastModified = headerValue(entry.head.headers, 'last-modified');
    return [
      for (final h in headers)
        if (!drop.contains(h.name.toLowerCase())) h,
      if (etag != null) (name: 'If-None-Match', value: etag),
      if (lastModified != null)
        (name: 'If-Modified-Since', value: lastModified),
    ];
  }

  // --- Responses ------------------------------------------------------------

  void _onResponseEvents(List<HttpStreamEvent> events) {
    for (final e in events) {
      if (_ignoreUpstream) return;
      switch (e) {
        case HttpResponseHeadEvent(:final head):
          _onResponseHead(head, e.raw);
        case HttpBodyEvent():
          final ex = _awaiting.firstOrNull;
          if (ex == null) {
            toClient(e.raw);
            break;
          }
          _touchIdle(ex);
          if (!ex.swallow) _emit(ex, e.raw);
          final capture = ex.capture;
          if (capture != null) {
            capture.add(e.raw);
            if (capture.length > cache!.options.maxEntryBytes) {
              ex.capture = null;
            }
          }
        case HttpMessageEndEvent():
          final ex = _awaiting.firstOrNull;
          if (ex != null && ex.response != null) _finish(ex);
        case HttpPassthroughEvent():
          _cancelAllTimers();
          final ex = _awaiting.firstOrNull;
          if (ex != null) {
            _emit(ex, e.raw);
          } else {
            toClient(e.raw);
          }
        case HttpGapEvent():
          final ex = _awaiting.firstOrNull;
          if (ex == null) {
            toClient(e.raw);
          } else {
            _emit(ex, e.raw);
          }
        case HttpRequestHeadEvent():
          break;
      }
    }
  }

  void _onResponseHead(HttpResponseHead head, Uint8List raw) {
    final ex = _awaiting.firstOrNull;
    if (ex == null) {
      toClient(raw);
      return;
    }
    final status = head.status;
    if (status >= 100 && status < 200) {
      // Interim, or 101 Switching Protocols (the rest then passes through).
      _emit(ex, raw);
      if (status == 101) {
        ex.store = false;
        _cancelAllTimers();
      }
      return;
    }
    ex
      ..response = head
      ..responseTime = _now();
    ex.headerTimer?.cancel();
    ex.headerTimer = null;
    _touchIdle(ex);
    final entry = ex.revalidating;
    if (entry != null && status == 304) {
      ex.swallow = true;
      return;
    }
    if (entry != null) cache!.recordMiss();
    if (ex.store && ex.request.method == 'GET') {
      ex.capture = BytesBuilder(copy: false);
    }
    ex.finalHeadSent = true;
    _emit(ex, encodeHttpResponseHead(_withStatus(head, ex.status)));
  }

  void _finish(_Exchange ex) {
    _awaiting.removeFirst();
    ex.cancelTimers();
    final head = ex.response!;
    final entry = ex.revalidating;
    final c = cache;
    if (ex.swallow && entry != null && c != null) {
      c
        ..refresh(
          entry,
          head,
          requestTime: ex.requestTime!,
          responseTime: ex.responseTime!,
        )
        ..recordRevalidated();
      // A cookie on the 304 is for this client alone: pass it on, unstored.
      ex.out.add(
        _serve(
          entry,
          ex.request,
          'REVALIDATED',
          extra: [
            for (final h in head.headers)
              if (h.name.toLowerCase() == 'set-cookie') h,
          ],
        ),
      );
    } else if (c != null) {
      final capture = ex.capture;
      if (capture != null) {
        c.store(
          request: ex.request,
          response: head,
          body: capture.takeBytes(),
          requestTime: ex.requestTime!,
          responseTime: ex.responseTime!,
        );
      }
      if (_isUnsafe(ex.request.method) &&
          head.status >= 200 &&
          head.status < 400) {
        _invalidateAfterUnsafe(c, ex.request, head);
      }
    }
    ex.done = true;
    _drain();
    _armHeaderTimer();
  }

  static bool _isUnsafe(String method) =>
      !const {'GET', 'HEAD', 'OPTIONS', 'TRACE'}.contains(method);

  static void _invalidateAfterUnsafe(
    HttpCache cache,
    HttpRequestHead request,
    HttpResponseHead head,
  ) {
    cache.invalidate(HttpCache.keyFor(request));
    final host = headerValue(request.headers, 'host');
    for (final name in ['location', 'content-location']) {
      final v = headerValue(head.headers, name);
      if (v == null) continue;
      final uri = Uri.tryParse(v);
      if (uri == null) continue;
      // Only same-host targets (RFC 9111 §4.4).
      if (uri.hasAuthority &&
          (host == null || uri.authority.toLowerCase() != host.toLowerCase())) {
        continue;
      }
      final target = uri.hasAuthority
          ? (uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path)
          : v;
      cache.invalidate(
        HttpCache.keyFor((
          method: 'GET',
          target: target.isEmpty ? '/' : target,
          version: '1.1',
          headers: request.headers,
        )),
      );
    }
  }

  // --- Ordering -------------------------------------------------------------

  void _emit(_Exchange ex, Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (identical(_queue.firstOrNull, ex)) {
      toClient(bytes);
    } else {
      ex.out.add(bytes);
    }
  }

  /// Sends every completed response at the front of the queue, in order; closes
  /// the connection once it is ending and nothing is left.
  void _drain() {
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if (head.out.isNotEmpty) toClient(head.out.takeBytes());
      if (!head.done) break;
      _queue.removeFirst();
    }
    if (_closing && _queue.isEmpty) _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _cancelAllTimers();
    closeConnection();
  }

  // --- Failures and timers --------------------------------------------------

  static Duration? _limit(Duration? d) =>
      d == null || d <= Duration.zero ? null : d;

  void _armHeaderTimer() {
    final limit = _limit(timeouts.responseHeader);
    final ex = _awaiting.firstOrNull;
    if (ex == null || _closed || limit == null) return;
    if (!ex.requestSent || ex.response != null || ex.headerTimer != null) {
      return;
    }
    ex.headerTimer = _timer(limit, () {
      if (identical(_awaiting.firstOrNull, ex) && ex.response == null) {
        _fail(ex, 504, 'Gateway Timeout');
      }
    });
  }

  void _touchIdle(_Exchange ex) {
    final limit = _limit(timeouts.idle);
    if (limit == null) return;
    ex.idleTimer?.cancel();
    ex.idleTimer = _timer(limit, () {
      if (identical(_awaiting.firstOrNull, ex)) _abort();
    });
  }

  void _onMaxDuration(_Exchange ex) {
    // Exchanges are sent in order, so the front one always expires first and
    // its failure clears the rest; a later one can only be done here.
    if (ex.done || !identical(_awaiting.firstOrNull, ex)) return;
    if (ex.finalHeadSent) {
      _abort();
    } else {
      _fail(ex, 504, 'Gateway Timeout');
    }
  }

  void _syncClientTimer() {
    final limit = _limit(timeouts.clientHeader);
    if (limit == null || _closing || _closed) return;
    if (_requests.isReadingHead) {
      _clientTimer ??= _timer(limit, _onClientTimeout);
    } else {
      _clientTimer?.cancel();
      _clientTimer = null;
    }
  }

  void _onClientTimeout() {
    _clientTimer = null;
    if (_closing || _closed || !_requests.isReadingHead) return;
    // Answer after every earlier response, then close.
    final request = (
      method: 'GET',
      target: '/',
      version: '1.1',
      headers: const <HeaderField>[],
    );
    _queue.add(
      _Exchange(request)
        ..out.add(_errorResponse(request, 408, 'Request Timeout', null))
        ..done = true,
    );
    _closing = true;
    _drain();
  }

  /// The origin failed [ex] before any response byte: answer it with [status]
  /// (or a `stale-if-error` entry), drop everything after it, and close.
  void _fail(_Exchange ex, int status, String reason) {
    ex.cancelTimers();
    _ignoreUpstream = true;
    _closing = true;
    final c = cache;
    final stale = ex.revalidating ?? ex.stale;
    final Uint8List response;
    if (c != null &&
        stale != null &&
        c.canServeStaleOnError(stale, ex.request)) {
      response = _serve(stale, ex.request, 'STALE', close: true);
    } else {
      response = _errorResponse(ex.request, status, reason, ex.status);
    }
    ex
      ..out.add(response)
      ..done = true;
    // Later requests can no longer be answered in order on this connection.
    while (_queue.isNotEmpty && !identical(_queue.last, ex)) {
      _queue.removeLast().cancelTimers();
    }
    for (final other in _awaiting) {
      other.cancelTimers();
    }
    _awaiting.clear();
    _drain();
  }

  /// A response already started cannot be failed cleanly: just close.
  void _abort() {
    _ignoreUpstream = true;
    _closing = true;
    _queue.clear();
    _awaiting.clear();
    _close();
  }

  void _cancelAllTimers() {
    _clientTimer?.cancel();
    _clientTimer = null;
    for (final ex in _queue) {
      ex.cancelTimers();
    }
  }

  // --- Responses built by the relay -----------------------------------------

  HttpResponseHead _withStatus(HttpResponseHead head, String? status) {
    if (cache == null || status == null) return head;
    final lower = cacheStatusHeader.toLowerCase();
    return (
      version: head.version,
      status: head.status,
      reason: head.reason,
      headers: [
        for (final h in head.headers)
          if (h.name.toLowerCase() != lower) h,
        (name: cacheStatusHeader, value: status),
      ],
    );
  }

  /// [entry] as a response to [request]: a `304` when the client's own
  /// preconditions match, the head alone for `HEAD`, otherwise head + body.
  Uint8List _serve(
    HttpCacheEntry entry,
    HttpRequestHead request,
    String status, {
    bool close = false,
    List<HeaderField> extra = const [],
  }) {
    final age = entry.age(_now()).inSeconds;
    final headers = [
      for (final h in entry.head.headers)
        if (h.name.toLowerCase() != 'age') h,
      ...extra,
      (name: 'Age', value: '$age'),
      if (close) (name: 'Connection', value: 'close'),
    ];
    if (_notModified(entry, request)) {
      const framing = {'content-length', 'transfer-encoding', 'trailer'};
      return encodeHttpResponseHead(
        _withStatus((
          version: '1.1',
          status: 304,
          reason: 'Not Modified',
          headers: [
            for (final h in headers)
              if (!framing.contains(h.name.toLowerCase())) h,
          ],
        ), status),
      );
    }
    final head = encodeHttpResponseHead(
      _withStatus((
        version: '1.1',
        status: entry.head.status,
        reason: entry.head.reason,
        headers: headers,
      ), status),
    );
    if (request.method == 'HEAD' || entry.body.isEmpty) return head;
    return (BytesBuilder(copy: false)
          ..add(head)
          ..add(entry.body))
        .takeBytes();
  }

  static bool _notModified(HttpCacheEntry entry, HttpRequestHead request) {
    if (entry.head.status != 200) return false;
    final inm = headerValue(request.headers, 'if-none-match');
    if (inm != null) {
      final etag = headerValue(entry.head.headers, 'etag');
      if (inm.trim() == '*') return etag != null;
      if (etag == null) return false;
      final want = _weak(etag);
      return inm.split(',').any((t) => _weak(t) == want);
    }
    final ims = parseHttpDate(
      headerValue(request.headers, 'if-modified-since'),
    );
    final lm = parseHttpDate(headerValue(entry.head.headers, 'last-modified'));
    return ims != null && lm != null && !lm.isAfter(ims);
  }

  static String _weak(String tag) {
    final t = tag.trim();
    return t.startsWith('W/') ? t.substring(2) : t;
  }

  /// A short plain-text error that closes the connection.
  Uint8List _errorResponse(
    HttpRequestHead request,
    int status,
    String reason,
    String? cacheStatus,
  ) {
    final body = utf8.encode('$status $reason\n');
    final head = encodeHttpResponseHead(
      _withStatus((
        version: '1.1',
        status: status,
        reason: reason,
        headers: [
          (name: 'Content-Type', value: 'text/plain; charset=utf-8'),
          (name: 'Content-Length', value: '${body.length}'),
          (name: 'Cache-Control', value: 'no-store'),
          (name: 'Connection', value: 'close'),
        ],
      ), cacheStatus),
    );
    if (request.method == 'HEAD') return head;
    return (BytesBuilder(copy: false)
          ..add(head)
          ..add(body))
        .takeBytes();
  }
}

class _Exchange {
  final HttpRequestHead request;

  /// Bytes ready for the client but held until earlier responses finish.
  final BytesBuilder out = BytesBuilder(copy: false);

  /// Whether the whole response is in [out] (or already sent).
  bool done = false;

  /// Offer the response to the cache.
  bool store = false;

  /// The cache-status label for a forwarded response.
  String? status;

  /// The stale entry being revalidated, if any.
  HttpCacheEntry? revalidating;

  /// A stale entry without validators, kept for `stale-if-error`.
  HttpCacheEntry? stale;

  /// Drop the origin response (a `304` answering our revalidation).
  bool swallow = false;

  /// The request, body included, has been sent to the origin.
  bool requestSent = false;

  /// The final response head has gone towards the client.
  bool finalHeadSent = false;

  HttpResponseHead? response;
  DateTime? requestTime;
  DateTime? responseTime;
  BytesBuilder? capture;
  Timer? headerTimer;
  Timer? idleTimer;
  Timer? maxTimer;

  _Exchange(this.request);

  void cancelTimers() {
    headerTimer?.cancel();
    idleTimer?.cancel();
    maxTimer?.cancel();
    headerTimer = idleTimer = maxTimer = null;
  }
}
