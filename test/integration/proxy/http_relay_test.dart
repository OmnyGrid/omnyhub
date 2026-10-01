@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// A raw TCP relay with [HttpRelay] (cache + timeouts) in front of a real
/// [HttpServer] — the shape of an HTTP tunnel.
void main() {
  late HttpServer origin;
  late ServerSocket front;
  late HttpCache cache;
  final hits = <String, int>{};
  var connections = 0;

  Future<void> start({
    HttpRelayTimeouts timeouts = const HttpRelayTimeouts(),
  }) async {
    hits.clear();
    connections = 0;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      final path = req.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      await req.drain<void>();
      final res = req.response;
      switch (path) {
        case '/hang':
          return; // never answers
        case '/static.css':
          res.headers
            ..set('cache-control', 'public, max-age=60')
            ..set('etag', '"v1"');
          res.write('body { color: red }');
        case '/private':
          res.headers.set('cache-control', 'private, max-age=60');
          res.write('mine');
        case '/vary':
          res.headers
            ..set('cache-control', 'max-age=60')
            ..set('vary', 'accept-language');
          res.write('lang=${req.headers.value('accept-language')}');
        default:
          res.write('dynamic ${hits[path]}');
      }
      await res.close();
    });

    cache = HttpCache(const HttpCacheOptions(maxBytes: 1 << 20));
    front = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    front.listen((client) async {
      connections++;
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        origin.port,
      );
      final relay = HttpRelay(
        cache: cache,
        timeouts: timeouts,
        toUpstream: upstream.add,
        toClient: client.add,
        closeConnection: () async {
          await client.flush();
          client.destroy();
          upstream.destroy();
        },
      );
      client.listen(
        relay.addFromClient,
        onDone: () {
          relay.dispose();
          upstream.destroy();
        },
        onError: (_) => upstream.destroy(),
      );
      upstream.listen(
        relay.addFromUpstream,
        onDone: relay.closeUpstream,
        onError: (_) => relay.closeUpstream(),
      );
    });
  }

  tearDown(() async {
    await front.close();
    await origin.close(force: true);
  });

  HttpClient http() {
    final c = HttpClient();
    addTearDown(() => c.close(force: true));
    return c;
  }

  Future<(int, String, HttpHeaders)> get(
    HttpClient c,
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final req = await c.get('127.0.0.1', front.port, path);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return (res.statusCode, body, res.headers);
  }

  test('static responses are served from the cache', () async {
    await start();
    final c = http();
    final first = await get(c, '/static.css');
    expect(first.$1, 200);
    expect(first.$3.value('x-cache'), 'MISS');
    for (var i = 0; i < 5; i++) {
      final again = await get(c, '/static.css');
      expect(again.$2, 'body { color: red }');
      expect(again.$3.value('x-cache'), 'HIT');
      expect(again.$3.value('age'), isNotNull);
    }
    expect(hits['/static.css'], 1, reason: 'the origin saw one request');
    expect(connections, 1);
    expect(cache.stats.hits, 5);

    // A conditional request is answered 304 from the cache.
    final cond = await get(
      c,
      '/static.css',
      headers: {'if-none-match': '"v1"'},
    );
    expect(cond.$1, 304);
    expect(hits['/static.css'], 1);
  });

  test('dynamic and private responses go to the origin', () async {
    await start();
    final c = http();
    expect((await get(c, '/dyn')).$2, 'dynamic 1');
    expect((await get(c, '/dyn')).$2, 'dynamic 2');
    await get(c, '/private');
    await get(c, '/private');
    expect(hits['/private'], 2);
  });

  test('Vary keeps a copy per request header value', () async {
    await start();
    final c = http();
    final en = await get(c, '/vary', headers: {'accept-language': 'en'});
    final pt = await get(c, '/vary', headers: {'accept-language': 'pt'});
    final en2 = await get(c, '/vary', headers: {'accept-language': 'en'});
    expect([en.$2, pt.$2, en2.$2], ['lang=en', 'lang=pt', 'lang=en']);
    expect(en2.$3.value('x-cache'), 'HIT');
    expect(hits['/vary'], 2);
  });

  test('a silent origin gets a 504 and the connection closes', () async {
    await start(
      timeouts: const HttpRelayTimeouts(
        responseHeader: Duration(milliseconds: 300),
      ),
    );
    final sw = Stopwatch()..start();
    final r = await get(http(), '/hang');
    expect(r.$1, 504);
    expect(r.$2, '504 Gateway Timeout\n');
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    // The next request needs (and gets) a new connection.
    expect((await get(http(), '/static.css')).$1, 200);
    expect(connections, 2);
  });

  test('a raw pipelined burst keeps responses in order', () async {
    await start();
    // Warm the cache.
    await get(http(), '/static.css');
    final s = await Socket.connect(InternetAddress.loopbackIPv4, front.port);
    addTearDown(s.destroy);
    final out = StringBuffer();
    final done = Completer<void>();
    s.listen((d) {
      out.write(latin1.decode(d));
      // The origin answers chunked: wait for the last terminating chunk.
      final text = out.toString();
      if (text.contains('dynamic 2') &&
          text.endsWith('0\r\n\r\n') &&
          !done.isCompleted) {
        done.complete();
      }
    });
    s.write(
      'GET /x HTTP/1.1\r\nHost: h\r\n\r\n'
      'GET /static.css HTTP/1.1\r\nHost: h\r\n\r\n'
      'GET /x HTTP/1.1\r\nHost: h\r\n\r\n',
    );
    await done.future.timeout(const Duration(seconds: 10));
    final text = out.toString();
    final a = text.indexOf('dynamic 1');
    final b = text.indexOf('color: red');
    final c = text.indexOf('dynamic 2');
    expect(a, lessThan(b));
    expect(b, lessThan(c));
  });
}
