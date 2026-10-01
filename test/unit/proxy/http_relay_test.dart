import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// Manual timers: [elapse] fires whatever came due, in order.
class FakeTimers {
  Duration _now = Duration.zero;
  final List<_FakeTimer> _timers = [];

  Timer start(Duration d, void Function() cb) {
    final t = _FakeTimer(_now + d, cb);
    _timers.add(t);
    return t;
  }

  void elapse(Duration d) {
    final until = _now + d;
    while (true) {
      final due = _timers.where((t) => t.isActive && t.at <= until).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      _now = t.at;
      t.fire();
    }
    _now = until;
  }

  int get active => _timers.where((t) => t.isActive).length;
}

class _FakeTimer implements Timer {
  final Duration at;
  final void Function() cb;
  bool _active = true;

  _FakeTimer(this.at, this.cb);

  void fire() {
    _active = false;
    cb();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A relay with recorded traffic in both directions.
class Harness {
  final upstream = BytesBuilder();
  final client = BytesBuilder();
  final timers = FakeTimers();
  DateTime now = DateTime.utc(2026, 10, 1, 12);
  var closed = 0;
  late final HttpCache? cache;
  late final HttpRelay relay;

  Harness({
    bool withCache = true,
    HttpCacheOptions options = const HttpCacheOptions(maxBytes: 1 << 20),
    HttpRelayTimeouts timeouts = HttpRelayTimeouts.none,
    List<HeaderField> Function(HttpRequestHead)? rewrite,
  }) {
    cache = withCache ? HttpCache(options, now: () => now) : null;
    relay = HttpRelay(
      cache: cache,
      timeouts: timeouts,
      rewriteRequest: rewrite,
      toUpstream: upstream.add,
      toClient: client.add,
      closeConnection: () => closed++,
      timer: timers.start,
      now: () => now,
    );
  }

  void fromClient(String s) => relay.addFromClient(latin1.encode(s));
  void fromOrigin(String s) => relay.addFromUpstream(latin1.encode(s));

  String takeUpstream() => latin1.decode(upstream.takeBytes());
  String takeClient() => latin1.decode(client.takeBytes());
}

String req(String target, [String extra = '']) =>
    'GET $target HTTP/1.1\r\nHost: h\r\n$extra\r\n';

String resp(
  String body, {
  String cc = 'max-age=60',
  String extra = '',
  int status = 200,
}) =>
    'HTTP/1.1 $status OK\r\nCache-Control: $cc\r\n$extra'
    'Content-Length: ${body.length}\r\n\r\n$body';

void main() {
  group('caching', () {
    test('a miss is stored and the next request is a hit', () {
      final h = Harness();
      h.fromClient(req('/a'));
      expect(h.takeUpstream(), req('/a'));
      h.fromOrigin(resp('hello'));
      expect(h.takeClient(), contains('X-Cache: MISS\r\n'));

      h.fromClient(req('/a'));
      expect(h.takeUpstream(), isEmpty, reason: 'served from cache');
      final hit = h.takeClient();
      expect(hit, startsWith('HTTP/1.1 200 OK\r\n'));
      expect(hit, contains('Age: 0\r\n'));
      expect(hit, contains('X-Cache: HIT\r\n'));
      expect(hit, endsWith('\r\n\r\nhello'));
      expect(h.cache!.stats.hits, 1);
      expect(h.cache!.stats.misses, 1);
    });

    test('Age grows; HEAD is answered from a GET entry', () {
      final h = Harness();
      h.fromClient(req('/a'));
      h.fromOrigin(resp('hello'));
      h.takeClient();
      h.now = h.now.add(const Duration(seconds: 7));
      h.fromClient('HEAD /a HTTP/1.1\r\nHost: h\r\n\r\n');
      final head = h.takeClient();
      expect(head, contains('Age: 7\r\n'));
      expect(
        head,
        endsWith('Content-Length: 5\r\nAge: 7\r\nX-Cache: HIT\r\n\r\n'),
      );
    });

    test("a client's matching If-None-Match gets a 304 from cache", () {
      final h = Harness();
      h.fromClient(req('/e'));
      h.fromOrigin(resp('hello', extra: 'ETag: "v1"\r\n'));
      h.takeClient();
      h.fromClient(req('/e', 'If-None-Match: W/"v1"\r\n'));
      final r = h.takeClient();
      expect(r, startsWith('HTTP/1.1 304 Not Modified\r\n'));
      expect(r, isNot(contains('Content-Length')));
      expect(r, endsWith('\r\n\r\n'));
      h.fromClient(req('/e', 'If-None-Match: "other"\r\n'));
      expect(h.takeClient(), startsWith('HTTP/1.1 200 OK'));
      h.fromClient(req('/e', 'If-None-Match: *\r\n'));
      expect(h.takeClient(), startsWith('HTTP/1.1 304'));
    });

    test('If-Modified-Since against Last-Modified', () {
      final h = Harness();
      final lm = formatHttpDate(DateTime.utc(2026, 1, 1));
      h.fromClient(req('/l'));
      h.fromOrigin(resp('hello', extra: 'Last-Modified: $lm\r\n'));
      h.takeClient();
      h.fromClient(req('/l', 'If-Modified-Since: $lm\r\n'));
      expect(h.takeClient(), startsWith('HTTP/1.1 304'));
      h.fromClient(
        req(
          '/l',
          'If-Modified-Since: ${formatHttpDate(DateTime.utc(2025))}\r\n',
        ),
      );
      expect(h.takeClient(), startsWith('HTTP/1.1 200'));
    });

    test('a stale entry is revalidated; a 304 serves the cached body', () {
      final h = Harness();
      h.fromClient(req('/r'));
      h.fromOrigin(resp('hello', cc: 'max-age=1', extra: 'ETag: "v1"\r\n'));
      h
        ..takeClient()
        ..takeUpstream();
      h.now = h.now.add(const Duration(seconds: 5));

      h.fromClient(req('/r'));
      expect(h.takeUpstream(), req('/r', 'If-None-Match: "v1"\r\n'));
      h.fromOrigin(
        'HTTP/1.1 304 Not Modified\r\nCache-Control: max-age=30\r\n\r\n',
      );
      final r = h.takeClient();
      expect(r, contains('X-Cache: REVALIDATED\r\n'));
      expect(r, endsWith('hello'));
      expect(h.cache!.stats.revalidated, 1);
      // Fresh again for 30s.
      h.fromClient(req('/r'));
      expect(h.takeUpstream(), isEmpty);
      expect(h.takeClient(), contains('X-Cache: HIT'));
    });

    test('revalidation answered with a 200 replaces the entry', () {
      final h = Harness();
      final lm = formatHttpDate(DateTime.utc(2026, 1, 1));
      h.fromClient(req('/r'));
      h.fromOrigin(
        resp('old!!', cc: 'max-age=1', extra: 'Last-Modified: $lm\r\n'),
      );
      h.takeClient();
      h.now = h.now.add(const Duration(seconds: 5));
      h.fromClient(req('/r'));
      expect(h.takeUpstream(), contains('If-Modified-Since: $lm\r\n'));
      h.fromOrigin(resp('new!!'));
      expect(h.takeClient(), endsWith('X-Cache: MISS\r\n\r\nnew!!'));
      h.fromClient(req('/r'));
      expect(h.takeClient(), endsWith('new!!'));
    });

    test('chunked responses are stored and replayed byte for byte', () {
      final h = Harness();
      const chunked =
          'HTTP/1.1 200 OK\r\nCache-Control: max-age=60\r\n'
          'Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n';
      h.fromClient(req('/c'));
      h.fromOrigin(chunked);
      h.takeClient();
      h.fromClient(req('/c'));
      expect(h.takeClient(), endsWith('\r\n\r\n3\r\nabc\r\n0\r\n\r\n'));
    });

    test('responses arrive in order when a hit follows a pending miss', () {
      final h = Harness();
      h.fromClient(req('/hit'));
      h.fromOrigin(resp('HIT!!'));
      h
        ..takeClient()
        ..takeUpstream();
      // Pipelined: a miss, then a hit, then another miss.
      h.fromClient('${req('/slow')}${req('/hit')}${req('/slow2')}');
      expect(h.takeUpstream(), '${req('/slow')}${req('/slow2')}');
      expect(h.takeClient(), isEmpty, reason: 'the hit waits for /slow');
      h.fromOrigin(resp('slow1', cc: 'no-store'));
      final out = h.takeClient();
      expect(out.indexOf('slow1'), lessThan(out.indexOf('HIT!!')));
      h.fromOrigin(resp('slow2', cc: 'no-store'));
      expect(h.takeClient(), endsWith('slow2'));
    });

    test('a successful POST invalidates the target and its Location', () {
      final h = Harness();
      for (final p in ['/items', '/items/1']) {
        h.fromClient(req(p));
        h.fromOrigin(resp('cache'));
      }
      h.takeClient();
      h.fromClient(
        'POST /items HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi',
      );
      expect(h.takeUpstream(), endsWith('\r\n\r\nhi'));
      h.fromOrigin(
        'HTTP/1.1 201 Created\r\nLocation: http://h/items/1\r\n'
        'Content-Length: 0\r\n\r\n',
      );
      expect(h.takeClient(), contains('X-Cache: BYPASS'));
      h.fromClient('${req('/items')}${req('/items/1')}');
      expect(h.takeUpstream(), '${req('/items')}${req('/items/1')}');
    });

    test('a failed POST or another host in Location invalidates nothing', () {
      final h = Harness();
      h.fromClient(req('/x'));
      h.fromOrigin(resp('cache'));
      h.fromClient('DELETE /x HTTP/1.1\r\nHost: h\r\n\r\n');
      h.fromOrigin('HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n');
      h.fromClient('PUT /y HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n');
      h.fromOrigin(
        'HTTP/1.1 200 OK\r\nContent-Location: http://evil/x\r\n'
        'Content-Length: 0\r\n\r\n',
      );
      h.takeUpstream();
      h.fromClient(req('/x'));
      expect(h.takeUpstream(), isEmpty);
    });

    test('a relative Location is invalidated too', () {
      final h = Harness();
      h.fromClient(req('/z'));
      h.fromOrigin(resp('cache'));
      h.fromClient(
        'PATCH /other HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n',
      );
      h.fromOrigin('HTTP/1.1 204 No Content\r\nLocation: /z\r\n\r\n');
      h.takeUpstream();
      h.fromClient(req('/z'));
      expect(h.takeUpstream(), req('/z'));
    });

    test('only-if-cached with nothing stored is a 504', () {
      final h = Harness();
      h.fromClient(req('/none', 'Cache-Control: only-if-cached\r\n'));
      expect(h.takeUpstream(), isEmpty);
      expect(h.takeClient(), startsWith('HTTP/1.1 504 Gateway Timeout'));
      expect(h.closed, 0, reason: 'nothing went wrong upstream');
    });

    test('an oversized response is relayed but not stored', () {
      final h = Harness(
        options: const HttpCacheOptions(maxBytes: 1 << 20, maxEntryBytes: 300),
      );
      final big = 'x' * 400;
      h.fromClient(req('/big'));
      h.fromOrigin(resp(big.substring(0, 100)).replaceFirst('100', '400'));
      h.fromOrigin(big.substring(100));
      expect(h.takeClient(), endsWith(big));
      h.fromClient(req('/big'));
      expect(h.takeUpstream(), contains('GET /big'));
    });

    test('interim 100 Continue is forwarded', () {
      final h = Harness();
      h.fromClient(
        'POST /u HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\n'
        'Content-Length: 1\r\n\r\n',
      );
      h.fromOrigin('HTTP/1.1 100 Continue\r\n\r\n');
      expect(h.takeClient(), 'HTTP/1.1 100 Continue\r\n\r\n');
      h.fromClient('x');
      expect(h.takeUpstream(), endsWith('\r\n\r\nx'));
      h.fromOrigin('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
      expect(h.takeClient(), startsWith('HTTP/1.1 200'));
    });

    test('a WebSocket upgrade passes through both ways', () {
      final h = Harness();
      h.fromClient(
        'GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\n\r\n',
      );
      expect(h.takeUpstream(), contains('Upgrade: websocket'));
      h.fromOrigin('HTTP/1.1 101 Switching Protocols\r\n\r\n\x81\x01a');
      expect(h.takeClient(), endsWith('\r\n\r\n\x81\x01a'));
      h.fromClient('\x81\x01b');
      expect(h.takeUpstream(), '\x81\x01b');
      h.fromOrigin('\x81\x01c');
      expect(h.takeClient(), '\x81\x01c');
    });

    test('unparseable origin output passes through', () {
      final h = Harness();
      h.fromClient(req('/g'));
      h.fromOrigin('garbage\r\n\r\n');
      expect(h.takeClient(), 'garbage\r\n\r\n');
    });

    test('a response nobody asked for is relayed untouched', () {
      final h = Harness();
      h.fromOrigin('HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nz');
      expect(h.takeClient(), 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nz');
      h.fromOrigin('\r\n');
      expect(h.takeClient(), '\r\n');
      h.fromOrigin('not http\r\n\r\n');
      expect(h.takeClient(), 'not http\r\n\r\n');
    });

    test('stray CRLFs from the origin go with the current response', () {
      final h = Harness(withCache: false);
      h.fromClient(req('/a'));
      h.fromOrigin('\r\n${resp('ok')}');
      expect(h.takeClient(), '\r\n${resp('ok')}');
    });

    test('the request rewrite applies to forwarded requests', () {
      final h = Harness(
        rewrite: (head) => [...head.headers, (name: 'X-Fwd', value: '1')],
      );
      h.fromClient(req('/a'));
      expect(h.takeUpstream(), contains('X-Fwd: 1\r\n'));
    });
  });

  group('without a cache', () {
    test('requests and responses pass, with no X-Cache', () {
      final h = Harness(withCache: false);
      h.fromClient(req('/a'));
      expect(h.takeUpstream(), req('/a'));
      h.fromOrigin(resp('hello'));
      final r = h.takeClient();
      expect(r, resp('hello'));
      h.fromClient(req('/a'));
      expect(h.takeUpstream(), req('/a'), reason: 'never served locally');
    });
  });

  group('timeouts', () {
    const t = HttpRelayTimeouts(
      responseHeader: Duration(seconds: 10),
      idle: Duration(seconds: 5),
      clientHeader: Duration(seconds: 3),
      maxDuration: Duration(seconds: 30),
    );

    test('defaults: 60s / 5m / 60s / off; none disables all', () {
      const d = HttpRelayTimeouts();
      expect(d.responseHeader, const Duration(seconds: 60));
      expect(d.idle, const Duration(minutes: 5));
      expect(d.clientHeader, const Duration(seconds: 60));
      expect(d.maxDuration, isNull);
      expect(HttpRelayTimeouts.none.responseHeader, isNull);
    });

    test('no response head in time: 504 and close', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/slow'));
      h.timers.elapse(const Duration(seconds: 9));
      expect(h.takeClient(), isEmpty);
      h.timers.elapse(const Duration(seconds: 1));
      final r = h.takeClient();
      expect(r, startsWith('HTTP/1.1 504 Gateway Timeout\r\n'));
      expect(r, contains('Connection: close\r\n'));
      expect(r, contains('X-Cache: MISS\r\n'));
      expect(r, endsWith('504 Gateway Timeout\n'));
      expect(h.closed, 1);
      // Late origin bytes and new client bytes are ignored.
      h.fromOrigin(resp('late'));
      h.fromClient(req('/again'));
      expect(h.takeClient(), isEmpty);
      expect(h.takeUpstream(), req('/slow'));
      expect(h.timers.active, 0);
    });

    test('the header timer starts only once the request body is sent', () {
      final h = Harness(timeouts: t);
      h.fromClient('POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\n');
      h.timers.elapse(const Duration(seconds: 20));
      expect(h.closed, 0);
      h.fromClient('ok');
      h.timers.elapse(const Duration(seconds: 10));
      expect(h.takeClient(), startsWith('HTTP/1.1 504'));
    });

    test('a pipelined request is timed from when it reaches the front', () {
      final h = Harness(timeouts: t, withCache: false);
      h.fromClient('${req('/1')}${req('/2')}');
      h.timers.elapse(const Duration(seconds: 8));
      h.fromOrigin(resp('one'));
      h.timers.elapse(const Duration(seconds: 8));
      expect(h.closed, 0, reason: '/2 has waited only 8s at the front');
      h.timers.elapse(const Duration(seconds: 2));
      expect(h.takeClient(), endsWith('504 Gateway Timeout\n'));
    });

    test('a stalled body after the head: close without a status', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/s'));
      h.fromOrigin('HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nab');
      h.takeClient();
      h.timers.elapse(const Duration(seconds: 4));
      h.fromOrigin('cd'); // resets idle
      h.timers.elapse(const Duration(seconds: 4));
      expect(h.closed, 0);
      h.timers.elapse(const Duration(seconds: 1));
      expect(h.closed, 1);
      expect(h.takeClient(), 'cd');
    });

    test('max duration: 504 before the head, close after it', () {
      final h = Harness(
        timeouts: const HttpRelayTimeouts(
          responseHeader: null,
          idle: null,
          clientHeader: null,
          maxDuration: Duration(seconds: 30),
        ),
      );
      h.fromClient(req('/m'));
      h.timers.elapse(const Duration(seconds: 30));
      expect(h.takeClient(), startsWith('HTTP/1.1 504'));

      final h2 = Harness(
        timeouts: const HttpRelayTimeouts(
          responseHeader: null,
          idle: null,
          clientHeader: null,
          maxDuration: Duration(seconds: 30),
        ),
      );
      h2.fromClient(req('/m'));
      h2.fromOrigin('HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nab');
      h2.timers.elapse(const Duration(seconds: 30));
      expect(h2.closed, 1);
      expect(h2.takeClient(), isNot(contains('504')));
    });

    test('the front exchange expires first and closes for the queue', () {
      final h = Harness(
        withCache: false,
        timeouts: const HttpRelayTimeouts(
          responseHeader: null,
          idle: null,
          clientHeader: null,
          maxDuration: Duration(seconds: 10),
        ),
      );
      h.fromClient('${req('/1')}${req('/2')}');
      h.fromOrigin('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na');
      h.timers.elapse(const Duration(seconds: 10)); // /1 started: close
      expect(h.closed, 1);
    });

    test('a slow client head: 408 and close; idle keep-alive is free', () {
      final h = Harness(timeouts: t);
      h.timers.elapse(const Duration(minutes: 10));
      expect(h.closed, 0, reason: 'no partial head yet');
      h.fromClient('GET /x HTTP/1.1\r\nHo');
      h.timers.elapse(const Duration(seconds: 3));
      expect(h.takeClient(), startsWith('HTTP/1.1 408 Request Timeout\r\n'));
      expect(h.closed, 1);
    });

    test('a completed head cancels the client timer', () {
      final h = Harness(timeouts: t);
      h.fromClient('GET /x HTTP/1.1\r\nHo');
      h.timers.elapse(const Duration(seconds: 2));
      h.fromClient('st: h\r\n\r\n');
      h.fromOrigin(resp('ok'));
      h.timers.elapse(const Duration(seconds: 10));
      expect(h.closed, 0);
    });

    test('a 408 waits for earlier responses', () {
      final h = Harness(timeouts: t, withCache: false);
      h.fromClient('${req('/1')}GET /2 HT');
      h.timers.elapse(const Duration(seconds: 3));
      expect(h.takeClient(), isEmpty);
      h.fromOrigin(resp('one'));
      final out = h.takeClient();
      expect(out.indexOf('one'), lessThan(out.indexOf('408')));
      expect(h.closed, 1);
    });

    test('origin closing before a response: 502 and close', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/x'));
      h.relay.closeUpstream();
      expect(h.takeClient(), startsWith('HTTP/1.1 502 Bad Gateway\r\n'));
      expect(h.closed, 1);
    });

    test('origin closing mid-body: close; idle: just close', () {
      final h = Harness();
      h.fromClient(req('/x'));
      h.fromOrigin('HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nab');
      h.relay.closeUpstream();
      expect(h.closed, 1);

      final idle = Harness();
      idle.relay.closeUpstream();
      expect(idle.closed, 1);
      expect(idle.takeClient(), isEmpty);
    });

    test('a close-delimited body completes on close', () {
      final h = Harness(withCache: false);
      h.fromClient(req('/x'));
      h.fromOrigin('HTTP/1.1 200 OK\r\n\r\nall of it');
      h.relay.closeUpstream();
      expect(h.takeClient(), endsWith('all of it'));
      expect(h.closed, 1);
    });

    test('requests after a failed one are dropped, earlier hits kept', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/hit'));
      h.fromOrigin(resp('HIT!!'));
      h.takeClient();
      h.fromClient('${req('/slow')}${req('/hit')}');
      h.timers.elapse(const Duration(seconds: 10));
      final out = h.takeClient();
      expect(out, startsWith('HTTP/1.1 504'));
      expect(out, isNot(contains('HIT!!')));
    });

    test('stale-if-error serves the stale copy instead of a 504/502', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/s'));
      h.fromOrigin(resp('stale', cc: 'max-age=1, stale-if-error=60'));
      h.takeClient();
      h.now = h.now.add(const Duration(seconds: 10));
      h.fromClient(req('/s'));
      expect(h.takeUpstream(), contains('GET /s'));
      h.timers.elapse(const Duration(seconds: 10));
      final r = h.takeClient();
      expect(r, startsWith('HTTP/1.1 200 OK'));
      expect(r, contains('X-Cache: STALE\r\n'));
      expect(r, contains('Connection: close\r\n'));
      expect(r, endsWith('stale'));
      expect(h.closed, 1);

      // With a validator the entry is revalidated; a 502 also falls back.
      final h2 = Harness(timeouts: t);
      h2.fromClient(req('/v'));
      h2.fromOrigin(
        resp(
          'stale',
          cc: 'max-age=1, stale-if-error=60',
          extra: 'ETag: "1"\r\n',
        ),
      );
      h2.takeClient();
      h2.now = h2.now.add(const Duration(seconds: 10));
      h2.fromClient(req('/v'));
      h2.relay.closeUpstream();
      expect(h2.takeClient(), contains('X-Cache: STALE'));
    });

    test('past the stale-if-error window: the error is reported', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/s'));
      h.fromOrigin(resp('stale', cc: 'max-age=1, stale-if-error=5'));
      h.takeClient();
      h.now = h.now.add(const Duration(seconds: 30));
      h.fromClient(req('/s'));
      h.timers.elapse(const Duration(seconds: 10));
      expect(h.takeClient(), startsWith('HTTP/1.1 504'));
    });

    test('HEAD errors carry no body', () {
      final h = Harness(timeouts: t, withCache: false);
      h.fromClient('HEAD /x HTTP/1.1\r\nHost: h\r\n\r\n');
      h.timers.elapse(const Duration(seconds: 10));
      expect(h.takeClient(), endsWith('Connection: close\r\n\r\n'));
    });

    test('no timers after a protocol switch', () {
      final h = Harness(timeouts: t);
      h.fromClient(
        'GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\n\r\n',
      );
      h.fromOrigin('HTTP/1.1 101 Switching Protocols\r\n\r\n');
      h.timers.elapse(const Duration(hours: 1));
      expect(h.closed, 0);
      expect(h.timers.active, 0);
    });

    test('dispose cancels everything', () {
      final h = Harness(timeouts: t);
      h.fromClient(req('/x'));
      h.fromClient('GET /y HT');
      h.relay.dispose();
      expect(h.relay.isClosed, isTrue);
      h.timers.elapse(const Duration(hours: 1));
      expect(h.closed, 0);
      h.fromClient(req('/z'));
      h.fromOrigin(resp('x'));
      h.relay.closeUpstream();
      expect(h.closed, 0);
    });

    test('zero disables a limit', () {
      final h = Harness(
        timeouts: const HttpRelayTimeouts(
          responseHeader: Duration.zero,
          idle: Duration.zero,
          clientHeader: Duration.zero,
          maxDuration: Duration.zero,
        ),
      );
      h.fromClient(req('/x'));
      h.fromClient('GET /y HT');
      h.timers.elapse(const Duration(hours: 1));
      expect(h.closed, 0);
      expect(h.timers.active, 0);
    });
  });
}
