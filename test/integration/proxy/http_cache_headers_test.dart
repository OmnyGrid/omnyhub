@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// Cache behaviour and header fidelity through [HttpRelay], against a real
/// Dart [HttpServer] origin whose handlers each test defines. The origin is
/// Dart on purpose: it adds its own defaults (e.g. `Content-Type: text/plain`
/// on a bare `304`), the shape that broke cached pages in production.
void main() {
  late HttpServer origin;
  late ServerSocket front;
  late HttpCache cache;
  final routes = <String, FutureOr<void> Function(HttpRequest req)>{};
  final hits = <String, int>{};
  final seen = <String, List<HttpHeaders>>{};

  Future<void> start({
    HttpCacheOptions options = const HttpCacheOptions(maxBytes: 1 << 20),
  }) async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      final path = req.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      (seen[path] ??= []).add(req.headers);
      await req.drain<void>();
      final handler = routes[path];
      if (handler == null) {
        req.response.statusCode = 404;
      } else {
        await handler(req);
      }
      await req.response.close();
    });
    cache = HttpCache(options);
    front = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    front.listen((client) async {
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        origin.port,
      );
      final relay = HttpRelay(
        cache: cache,
        timeouts: HttpRelayTimeouts.none,
        toUpstream: upstream.add,
        toClient: client.add,
        closeConnection: () {
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
      upstream.listen(relay.addFromUpstream, onDone: relay.closeUpstream);
    });
  }

  setUp(() {
    routes.clear();
    hits.clear();
    seen.clear();
  });

  tearDown(() async {
    await front.close();
    await origin.close(force: true);
  });

  /// One request on a fresh client: status, raw body bytes, headers.
  Future<(int, Uint8List, HttpHeaders)> fetch(
    String path, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final c = HttpClient()..autoUncompress = false;
    addTearDown(() => c.close(force: true));
    final req = await c.open(method, '127.0.0.1', front.port, path);
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    if (body != null) req.write(body);
    final res = await req.close();
    final bytes = await res
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .timeout(const Duration(seconds: 15));
    return (res.statusCode, bytes.takeBytes(), res.headers);
  }

  String text(Uint8List b) => utf8.decode(b);

  group('header fidelity', () {
    test('a hit carries the same representation and metadata', () async {
      final lm = HttpDate.format(DateTime.utc(2026, 1, 2, 3, 4, 5));
      final expires = HttpDate.format(
        DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      final payload = Uint8List.fromList(List.generate(300, (i) => i % 256));
      routes['/asset.bin'] = (req) {
        req.response.headers
          ..contentType = ContentType('application', 'octet-stream')
          ..set('cache-control', 'public, max-age=600')
          ..set('etag', '"bin-1"')
          ..set('last-modified', lm)
          ..set('expires', expires)
          ..set('content-language', 'en')
          ..set('content-disposition', 'attachment; filename="a.bin"')
          ..set('x-app-version', '7')
          ..set('keep-alive', 'timeout=5')
          ..contentLength = payload.length;
        req.response.add(payload);
      };
      await start();

      final miss = await fetch('/asset.bin');
      final hit = await fetch('/asset.bin');
      expect(miss.$3.value('x-cache'), 'MISS');
      expect(hit.$3.value('x-cache'), 'HIT');
      expect(hits['/asset.bin'], 1);
      expect(hit.$2, payload);
      for (final name in [
        'content-type',
        'cache-control',
        'etag',
        'last-modified',
        'expires',
        'content-language',
        'content-disposition',
        'x-app-version',
        'content-length',
        'date',
      ]) {
        expect(hit.$3.value(name), miss.$3.value(name), reason: name);
      }
      expect(hit.$3.value('age'), isNotNull);
      expect(hit.$3.value('keep-alive'), isNull, reason: 'hop-by-hop');
    });

    test('a chunked response is replayed with the same body', () async {
      routes['/chunked'] = (req) {
        req.response.headers
          ..contentType = ContentType.json
          ..set('cache-control', 'max-age=60');
        req.response.write('{"a":');
        req.response.write('1}');
      };
      await start();
      await fetch('/chunked');
      final hit = await fetch('/chunked');
      expect(hit.$3.value('x-cache'), 'HIT');
      expect(hit.$3.contentType?.mimeType, 'application/json');
      expect(text(hit.$2), '{"a":1}');
    });

    test('HEAD from a cached GET has the headers and no body', () async {
      routes['/h'] = (req) {
        req.response.headers
          ..contentType = ContentType.html
          ..set('cache-control', 'max-age=60')
          ..contentLength = 11;
        if (req.method != 'HEAD') req.response.write('<p>hey</p>\n');
      };
      await start();
      await fetch('/h');
      final head = await fetch('/h', method: 'HEAD');
      expect(head.$3.value('x-cache'), 'HIT');
      expect(head.$3.contentType?.mimeType, 'text/html');
      expect(head.$3.value('content-length'), '11');
      expect(head.$2, isEmpty);
      expect(hits['/h'], 1);
    });

    test('gzip variants are kept apart by Vary: Accept-Encoding', () async {
      final plain = utf8.encode('hello ' * 50);
      routes['/z'] = (req) {
        final gz =
            req.headers.value('accept-encoding')?.contains('gzip') ?? false;
        req.response.headers
          ..contentType = ContentType.text
          ..set('cache-control', 'max-age=60')
          ..set('vary', 'Accept-Encoding');
        if (gz) {
          req.response.headers.set('content-encoding', 'gzip');
          req.response.add(gzip.encode(plain));
        } else {
          req.response.add(plain);
        }
      };
      await start();
      await fetch('/z', headers: {'accept-encoding': 'gzip'});
      await fetch('/z', headers: {'accept-encoding': 'identity'});
      final gz = await fetch('/z', headers: {'accept-encoding': 'gzip'});
      final id = await fetch('/z', headers: {'accept-encoding': 'identity'});
      expect(gz.$3.value('x-cache'), 'HIT');
      expect(id.$3.value('x-cache'), 'HIT');
      expect(gz.$3.value('content-encoding'), 'gzip');
      expect(gzip.decode(gz.$2), plain);
      expect(id.$3.value('content-encoding'), isNull);
      expect(id.$2, plain);
      expect(hits['/z'], 2);
    });
  });

  group('revalidation keeps the stored representation', () {
    test('ETag + no-cache: every use revalidates, type stays', () async {
      routes['/page'] = (req) {
        if (req.headers.value('if-none-match') == '"p1"') {
          req.response.statusCode = 304; // Dart adds text/plain here
          return;
        }
        req.response.headers
          ..contentType = ContentType.html
          ..set('cache-control', 'no-cache')
          ..set('etag', '"p1"');
        req.response.write('<h1>page</h1>');
      };
      await start();
      await fetch('/page');
      for (var i = 0; i < 2; i++) {
        final r = await fetch('/page');
        expect(r.$3.value('x-cache'), 'REVALIDATED');
        expect(r.$3.contentType?.mimeType, 'text/html');
        expect(text(r.$2), '<h1>page</h1>');
      }
      expect(hits['/page'], 3);
      expect(seen['/page']!.last.value('if-none-match'), '"p1"');
    });

    test('Last-Modified only: If-Modified-Since, then 304', () async {
      final lm = HttpDate.format(DateTime.utc(2026, 3, 1));
      routes['/lm'] = (req) {
        if (req.headers.value('if-modified-since') == lm) {
          req.response.statusCode = 304;
          return;
        }
        req.response.headers
          ..contentType = ContentType.html
          ..set('cache-control', 'max-age=0')
          ..set('last-modified', lm);
        req.response.write('lm');
      };
      await start();
      await fetch('/lm');
      final r = await fetch('/lm');
      expect(r.$3.value('x-cache'), 'REVALIDATED');
      expect(r.$3.contentType?.mimeType, 'text/html');
      expect(r.$3.value('last-modified'), lm);
    });

    test("a 304's new Cache-Control makes the entry fresh again", () async {
      routes['/ttl'] = (req) {
        if (req.headers.value('if-none-match') != null) {
          req.response.statusCode = 304;
          req.response.headers.set('cache-control', 'max-age=60');
          return;
        }
        req.response.headers
          ..contentType = ContentType.html
          ..set('cache-control', 'max-age=0')
          ..set('etag', '"t"');
        req.response.write('ttl');
      };
      await start();
      await fetch('/ttl');
      expect((await fetch('/ttl')).$3.value('x-cache'), 'REVALIDATED');
      final hit = await fetch('/ttl');
      expect(hit.$3.value('x-cache'), 'HIT');
      expect(hit.$3.value('cache-control'), 'max-age=60');
      expect(hit.$3.contentType?.mimeType, 'text/html');
      expect(hits['/ttl'], 2);
    });

    test("a 304's Set-Cookie reaches only the client that caused it", () async {
      routes['/c'] = (req) {
        if (req.headers.value('if-none-match') != null) {
          req.response.statusCode = 304;
          req.response.headers.set('set-cookie', 'sid=secret');
          return;
        }
        req.response.headers
          ..contentType = ContentType.html
          ..set('cache-control', 'no-cache')
          ..set('etag', '"c"');
        req.response.write('c');
      };
      await start();
      await fetch('/c');
      final first = await fetch('/c');
      expect(first.$3.value('x-cache'), 'REVALIDATED');
      expect(first.$3.value('set-cookie'), 'sid=secret');
      routes['/c'] = (req) {
        req.response.statusCode = 304; // this time without a cookie
      };
      final other = await fetch('/c');
      expect(other.$3.value('x-cache'), 'REVALIDATED');
      expect(other.$3.value('set-cookie'), isNull);
    });

    test('must-revalidate is honoured even with max-stale', () async {
      routes['/mr'] = (req) {
        if (req.headers.value('if-none-match') != null) {
          req.response.statusCode = 304;
          return;
        }
        req.response.headers
          ..set('cache-control', 'max-age=0, must-revalidate')
          ..set('etag', '"m"');
        req.response.write('m');
      };
      await start();
      await fetch('/mr');
      final r = await fetch('/mr', headers: {'cache-control': 'max-stale'});
      expect(r.$3.value('x-cache'), 'REVALIDATED');
    });
  });

  group('freshness sources', () {
    test('s-maxage beats max-age for this shared cache', () async {
      routes['/s'] = (req) {
        req.response.headers.set('cache-control', 'max-age=0, s-maxage=60');
        req.response.write('s');
      };
      await start();
      await fetch('/s');
      expect((await fetch('/s')).$3.value('x-cache'), 'HIT');
    });

    test('Expires in the future is fresh; in the past is not', () async {
      final future = HttpDate.format(
        DateTime.now().toUtc().add(const Duration(minutes: 10)),
      );
      final past = HttpDate.format(DateTime.utc(2000));
      routes['/future'] = (req) {
        req.response.headers.set('expires', future);
        req.response.write('f');
      };
      routes['/past'] = (req) {
        req.response.headers.set('expires', past);
        req.response.write('p');
      };
      await start();
      await fetch('/future');
      await fetch('/past');
      expect((await fetch('/future')).$3.value('x-cache'), 'HIT');
      expect((await fetch('/past')).$3.value('x-cache'), 'MISS');
    });

    test('no Cache-Control: uncached, unless a default TTL is set', () async {
      routes['/plain'] = (req) => req.response.write('plain');
      await start();
      await fetch('/plain');
      expect((await fetch('/plain')).$3.value('x-cache'), 'MISS');
      expect(hits['/plain'], 2);
    });

    test('the default TTL covers responses that state no lifetime', () async {
      routes['/plain'] = (req) => req.response.write('plain');
      await start(
        options: const HttpCacheOptions(
          maxBytes: 1 << 20,
          defaultTtl: Duration(minutes: 1),
        ),
      );
      await fetch('/plain');
      final hit = await fetch('/plain');
      expect(hit.$3.value('x-cache'), 'HIT');
      expect(hit.$3.contentType?.mimeType, 'text/plain');
    });
  });

  group('statuses', () {
    test('a 404 with max-age is cached; a 500 is not', () async {
      routes['/gone'] = (req) {
        req.response
          ..statusCode = 404
          ..headers.set('cache-control', 'max-age=60')
          ..write('nope');
      };
      routes['/boom'] = (req) {
        req.response
          ..statusCode = 500
          ..headers.set('cache-control', 'max-age=60')
          ..write('err');
      };
      await start();
      await fetch('/gone');
      await fetch('/boom');
      final gone = await fetch('/gone');
      expect(gone.$1, 404);
      expect(gone.$3.value('x-cache'), 'HIT');
      expect((await fetch('/boom')).$3.value('x-cache'), 'MISS');
    });

    test('a permanent redirect is cached with its Location', () async {
      routes['/old'] = (req) {
        req.response
          ..statusCode = 301
          ..headers.set('location', '/new')
          ..headers.set('cache-control', 'max-age=60');
      };
      await start();
      await fetch('/old');
      final r = await fetch('/old');
      expect(r.$1, 301);
      expect(r.$3.value('location'), '/new');
      expect(r.$3.value('x-cache'), 'HIT');
    });
  });

  group('what is never shared', () {
    test('Set-Cookie responses are never stored', () async {
      routes['/login'] = (req) {
        req.response.headers
          ..set('cache-control', 'max-age=60')
          ..set('set-cookie', 'sid=1');
        req.response.write('in');
      };
      await start();
      await fetch('/login');
      final again = await fetch('/login');
      expect(again.$3.value('x-cache'), 'MISS');
      expect(hits['/login'], 2);
    });

    test('private: only with cachePrivate', () async {
      routes['/me'] = (req) {
        req.response.headers.set('cache-control', 'private, max-age=60');
        req.response.write('me');
      };
      await start();
      await fetch('/me');
      expect((await fetch('/me')).$3.value('x-cache'), 'MISS');
      await front.close();
      await origin.close(force: true);
      await start(
        options: const HttpCacheOptions(maxBytes: 1 << 20, cachePrivate: true),
      );
      await fetch('/me');
      expect((await fetch('/me')).$3.value('x-cache'), 'HIT');
    });

    test('Authorization and Range requests bypass the cache', () async {
      routes['/s'] = (req) {
        req.response.headers.set('cache-control', 'public, max-age=60');
        req.response.write('0123456789');
      };
      await start();
      await fetch('/s');
      final authed = await fetch('/s', headers: {'authorization': 'Bearer t'});
      final ranged = await fetch('/s', headers: {'range': 'bytes=0-1'});
      expect(authed.$3.value('x-cache'), 'BYPASS');
      expect(ranged.$3.value('x-cache'), 'BYPASS');
      expect(hits['/s'], 3);
    });
  });

  group("the client's own directives", () {
    setUp(() {
      routes['/r'] = (req) {
        if (req.headers.value('if-none-match') == '"r"') {
          req.response.statusCode = 304;
          return;
        }
        req.response.headers
          ..contentType = ContentType.html
          ..set('cache-control', 'max-age=60')
          ..set('etag', '"r"');
        req.response.write('r');
      };
    });

    test('a hard refresh revalidates; no-store bypasses', () async {
      await start();
      await fetch('/r');
      for (final h in [
        {'cache-control': 'no-cache'},
        {'cache-control': 'max-age=0'},
        {'pragma': 'no-cache'},
      ]) {
        final r = await fetch('/r', headers: h);
        expect(r.$3.value('x-cache'), 'REVALIDATED', reason: '$h');
        expect(r.$3.contentType?.mimeType, 'text/html');
      }
      final ns = await fetch('/r', headers: {'cache-control': 'no-store'});
      expect(ns.$3.value('x-cache'), 'BYPASS');
    });

    test('only-if-cached: a hit, or 504 without a contacted origin', () async {
      await start();
      final none = await fetch(
        '/r',
        headers: {'cache-control': 'only-if-cached'},
      );
      expect(none.$1, 504);
      expect(hits['/r'], isNull);
      await fetch('/r');
      final hit = await fetch(
        '/r',
        headers: {'cache-control': 'only-if-cached'},
      );
      expect(hit.$3.value('x-cache'), 'HIT');
    });

    test('conditional requests are answered 304 from the cache', () async {
      await start();
      await fetch('/r');
      final inm = await fetch('/r', headers: {'if-none-match': '"r"'});
      expect(inm.$1, 304);
      expect(inm.$3.value('etag'), '"r"');
      expect(inm.$3.value('cache-control'), 'max-age=60');
      expect(inm.$2, isEmpty);
      expect(hits['/r'], 1);
    });
  });

  group('invalidation and limits', () {
    test('a successful POST drops the cached path', () async {
      var version = 1;
      routes['/doc'] = (req) {
        if (req.method == 'POST') {
          version++;
          req.response.statusCode = 204;
          return;
        }
        req.response.headers.set('cache-control', 'max-age=60');
        req.response.write('v$version');
      };
      await start();
      expect(text((await fetch('/doc')).$2), 'v1');
      expect(text((await fetch('/doc')).$2), 'v1');
      await fetch('/doc', method: 'POST', body: 'x');
      final after = await fetch('/doc');
      expect(after.$3.value('x-cache'), 'MISS');
      expect(text(after.$2), 'v2');
    });

    test('a response larger than the entry limit is not stored', () async {
      final big = 'x' * 5000;
      routes['/big'] = (req) {
        req.response.headers.set('cache-control', 'max-age=60');
        req.response.write(big);
      };
      await start(
        options: const HttpCacheOptions(maxBytes: 1 << 20, maxEntryBytes: 1024),
      );
      expect(text((await fetch('/big')).$2), big);
      expect((await fetch('/big')).$3.value('x-cache'), 'MISS');
      expect(cache.stats.entries, 0);
    });
  });
}
