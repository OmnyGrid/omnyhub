import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

HttpRequestHead get(
  String target, {
  String method = 'GET',
  String version = '1.1',
  List<HeaderField> headers = const [],
}) => (
  method: method,
  target: target,
  version: version,
  headers: [(name: 'Host', value: 'example.com'), ...headers],
);

HttpResponseHead ok({
  int status = 200,
  List<HeaderField> headers = const [
    (name: 'Cache-Control', value: 'max-age=60'),
  ],
  bool withLength = true,
}) => (
  version: '1.1',
  status: status,
  reason: 'OK',
  headers: [...headers, if (withLength) (name: 'Content-Length', value: '5')],
);

final body = Uint8List.fromList(utf8.encode('hello'));

void main() {
  late DateTime now;
  late HttpCache cache;

  HttpCache make({
    int maxBytes = 1 << 20,
    int maxEntryBytes = 1 << 16,
    bool cachePrivate = false,
    Duration? defaultTtl,
    HttpCacheBudget? budget,
  }) => HttpCache(
    HttpCacheOptions(
      maxBytes: maxBytes,
      maxEntryBytes: maxEntryBytes,
      cachePrivate: cachePrivate,
      defaultTtl: defaultTtl,
    ),
    budget: budget,
    now: () => now,
  );

  HttpCacheEntry? put(
    HttpCache c,
    HttpRequestHead req,
    HttpResponseHead resp, [
    Uint8List? b,
  ]) => c.store(
    request: req,
    response: resp,
    body: b ?? body,
    requestTime: now,
    responseTime: now,
  );

  setUp(() {
    now = DateTime.utc(2026, 10, 1, 12);
    cache = make();
  });

  group('lookup bypass', () {
    final cases = <String, HttpRequestHead>{
      'method': get('/', method: 'POST'),
      'http/1.0': get('/', version: '1.0'),
      'authorization': get(
        '/',
        headers: const [(name: 'Authorization', value: 'Bearer x')],
      ),
      'range': get('/', headers: const [(name: 'Range', value: 'bytes=0-1')]),
      'upgrade': get(
        '/',
        headers: const [(name: 'Upgrade', value: 'websocket')],
      ),
      'body': get('/', headers: const [(name: 'Content-Length', value: '3')]),
      'no-store': get(
        '/',
        headers: const [(name: 'Cache-Control', value: 'no-store')],
      ),
    };
    cases.forEach((reason, req) {
      test(reason, () {
        final r = cache.lookup(req);
        expect(r, isA<CacheBypass>());
        expect((r as CacheBypass).reason, reason);
      });
    });

    test('chunked request body bypasses', () {
      expect(
        cache.lookup(
          get(
            '/',
            headers: const [(name: 'Transfer-Encoding', value: 'chunked')],
          ),
        ),
        isA<CacheBypass>(),
      );
    });

    test('HEAD and Content-Length: 0 do not bypass', () {
      expect(cache.lookup(get('/', method: 'HEAD')), isA<CacheMiss>());
      expect(
        cache.lookup(
          get('/', headers: const [(name: 'Content-Length', value: '0')]),
        ),
        isA<CacheMiss>(),
      );
    });
  });

  group('whyNotStorable', () {
    String? why(
      HttpResponseHead r, {
      HttpRequestHead? req,
      HttpCache? c,
      int bytes = 5,
    }) => (c ?? cache).whyNotStorable(req ?? get('/'), r, bodyBytes: bytes);

    test('a max-age 200 is storable', () => expect(why(ok()), isNull));

    test('HEAD responses are not stored', () {
      expect(why(ok(), req: get('/', method: 'HEAD')), 'method');
    });

    test('request bypass reasons carry over', () {
      expect(why(ok(), req: get('/', method: 'PUT')), 'method');
    });

    test('status must be cacheable', () {
      expect(why(ok(status: 500)), 'status');
      for (final s in cacheableStatuses) {
        expect(why(ok(status: s)), isNull, reason: '$s');
      }
    });

    test('no-store, private, set-cookie, vary *', () {
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'no-store, max-age=9'),
            ],
          ),
        ),
        'no-store',
      );
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'private, max-age=9'),
            ],
          ),
        ),
        'private',
      );
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'max-age=9'),
              (name: 'Set-Cookie', value: 'a=b'),
            ],
          ),
        ),
        'set-cookie',
      );
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'max-age=9'),
              (name: 'Vary', value: 'Accept, *'),
            ],
          ),
        ),
        'vary',
      );
    });

    test('cachePrivate stores private, but never Set-Cookie', () {
      final c = make(cachePrivate: true);
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'private, max-age=9'),
            ],
          ),
          c: c,
        ),
        isNull,
      );
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'private, max-age=9'),
              (name: 'Set-Cookie', value: 'a=b'),
            ],
          ),
          c: c,
        ),
        'set-cookie',
      );
      expect(
        why(
          ok(),
          c: c,
          req: get('/', headers: const [(name: 'Authorization', value: 'x')]),
        ),
        'authorization',
      );
    });

    test('the length must be known', () {
      expect(why(ok(withLength: false)), 'length');
      expect(
        why(
          ok(
            withLength: false,
            headers: const [
              (name: 'Cache-Control', value: 'max-age=9'),
              (name: 'Transfer-Encoding', value: 'chunked'),
            ],
          ),
        ),
        isNull,
      );
      expect(why(ok(status: 204, withLength: false)), isNull);
    });

    test('without Cache-Control: only with a default TTL', () {
      expect(why(ok(headers: const [])), 'no-freshness');
      expect(
        why(
          ok(headers: const []),
          c: make(defaultTtl: const Duration(minutes: 5)),
        ),
        isNull,
      );
    });

    test('a zero lifetime needs a validator', () {
      expect(
        why(ok(headers: const [(name: 'Cache-Control', value: 'no-cache')])),
        'no-freshness',
      );
      expect(
        why(
          ok(
            headers: const [
              (name: 'Cache-Control', value: 'no-cache'),
              (name: 'ETag', value: '"v1"'),
            ],
          ),
        ),
        isNull,
      );
    });

    test('too large for the entry or the cache', () {
      expect(why(ok(), c: make(maxEntryBytes: 100)), 'too-large');
      expect(why(ok(), c: make(maxBytes: 100)), 'too-large');
    });
  });

  group('store / lookup', () {
    test('a stored entry is a hit while fresh, then a miss', () {
      final e = put(cache, get('/a'), ok())!;
      expect(e.body, body);
      expect(e.size, greaterThan(body.length));
      expect((cache.lookup(get('/a')) as CacheHit).entry, same(e));
      expect(
        (cache.lookup(get('/a', method: 'HEAD')) as CacheHit).entry,
        same(e),
      );
      now = now.add(const Duration(seconds: 61));
      expect(e.isFresh(now), isFalse);
      final miss = cache.lookup(get('/a')) as CacheMiss;
      expect(miss.stale, same(e));
    });

    test('a stale entry with a validator is revalidated', () {
      put(
        cache,
        get('/a'),
        ok(
          headers: const [
            (name: 'Cache-Control', value: 'max-age=1'),
            (name: 'ETag', value: '"v1"'),
          ],
        ),
      );
      now = now.add(const Duration(seconds: 5));
      expect(cache.lookup(get('/a')), isA<CacheRevalidate>());
    });

    test('keys include the host; HEAD and GET share them', () {
      put(cache, get('/a'), ok());
      final other = (
        method: 'GET',
        target: '/a',
        version: '1.1',
        headers: const [(name: 'Host', value: 'other.example')],
      );
      expect(cache.lookup(other), isA<CacheMiss>());
      expect(HttpCache.keyFor(get('/a')), 'example.com /a');
    });

    test('stored heads drop hop-by-hop fields, Age and X-Cache', () {
      final e = put(
        cache,
        get('/a'),
        ok(
          headers: const [
            (name: 'Cache-Control', value: 'max-age=60'),
            (name: 'Connection', value: 'keep-alive, X-Hop'),
            (name: 'Keep-Alive', value: 'timeout=5'),
            (name: 'X-Hop', value: '1'),
            (name: 'Age', value: '3'),
            (name: 'X-Cache', value: 'HIT'),
            (name: 'X-Keep', value: 'yes'),
          ],
        ),
      )!;
      expect(e.head.headers.map((h) => h.name), [
        'Cache-Control',
        'X-Keep',
        'Content-Length',
      ]);
      expect(e.initialAge, 3, reason: 'the Age header still counts');
    });

    test('Age and Date feed the initial age', () {
      final e = put(
        cache,
        get('/a'),
        ok(
          headers: [
            const (name: 'Cache-Control', value: 'max-age=60'),
            (
              name: 'Date',
              value: formatHttpDate(now.subtract(const Duration(seconds: 50))),
            ),
          ],
        ),
      )!;
      expect(e.initialAge, 50);
      expect(e.isFresh(now), isTrue);
      now = now.add(const Duration(seconds: 11));
      expect(e.isFresh(now), isFalse);
    });

    test('Vary keeps one variant per request value', () {
      HttpRequestHead lang(String l) =>
          get('/v', headers: [(name: 'Accept-Language', value: l)]);
      final varyResp = ok(
        headers: const [
          (name: 'Cache-Control', value: 'max-age=60'),
          (name: 'Vary', value: 'Accept-Language'),
        ],
      );
      final en = put(cache, lang('en'), varyResp)!;
      final pt = put(cache, lang('pt'), varyResp)!;
      expect((cache.lookup(lang('en')) as CacheHit).entry, same(en));
      expect((cache.lookup(lang('pt')) as CacheHit).entry, same(pt));
      expect(cache.lookup(lang('fr')), isA<CacheMiss>());
      expect(cache.lookup(get('/v')), isA<CacheMiss>());
      // A fresh response for the same variant replaces it.
      final en2 = put(cache, lang(' en '), varyResp)!;
      expect((cache.lookup(lang('en')) as CacheHit).entry, same(en2));
      expect(cache.stats.entries, 2);
    });

    test('non-storable responses return null', () {
      expect(put(cache, get('/a'), ok(status: 500)), isNull);
      expect(cache.stats.entries, 0);
    });
  });

  group('request directives', () {
    setUp(() {
      put(
        cache,
        get('/a'),
        ok(
          headers: const [
            (name: 'Cache-Control', value: 'max-age=60'),
            (name: 'ETag', value: '"v1"'),
          ],
        ),
      );
      now = now.add(const Duration(seconds: 30));
    });

    CacheLookup lookupWith(String cc) =>
        cache.lookup(get('/a', headers: [(name: 'Cache-Control', value: cc)]));

    test('no-cache and max-age=0 force revalidation', () {
      expect(lookupWith('no-cache'), isA<CacheRevalidate>());
      expect(lookupWith('max-age=0'), isA<CacheRevalidate>());
      expect(lookupWith('max-age=40'), isA<CacheHit>());
    });

    test('Pragma: no-cache counts only without Cache-Control', () {
      expect(
        cache.lookup(
          get('/a', headers: const [(name: 'Pragma', value: 'no-cache')]),
        ),
        isA<CacheRevalidate>(),
      );
      expect(
        cache.lookup(
          get(
            '/a',
            headers: const [
              (name: 'Pragma', value: 'no-cache'),
              (name: 'Cache-Control', value: 'max-age=99'),
            ],
          ),
        ),
        isA<CacheHit>(),
      );
    });

    test('min-fresh', () {
      expect(lookupWith('min-fresh=20'), isA<CacheHit>());
      expect(lookupWith('min-fresh=40'), isA<CacheRevalidate>());
    });

    test('max-stale accepts a stale entry within its window', () {
      now = now.add(const Duration(seconds: 40)); // 10s stale
      expect(lookupWith('max-stale=5'), isA<CacheRevalidate>());
      expect(lookupWith('max-stale=20'), isA<CacheHit>());
      expect(lookupWith('max-stale'), isA<CacheHit>());
    });

    test('only-if-cached', () {
      expect(lookupWith('only-if-cached'), isA<CacheHit>());
      now = now.add(const Duration(minutes: 5));
      expect(lookupWith('only-if-cached'), isA<CacheUnsatisfiable>());
      expect(
        cache.lookup(
          get(
            '/none',
            headers: const [(name: 'Cache-Control', value: 'only-if-cached')],
          ),
        ),
        isA<CacheUnsatisfiable>(),
      );
    });
  });

  test('must-revalidate refuses max-stale', () {
    put(
      cache,
      get('/m'),
      ok(
        headers: const [
          (name: 'Cache-Control', value: 'max-age=1, must-revalidate'),
        ],
      ),
    );
    now = now.add(const Duration(seconds: 5));
    expect(
      cache.lookup(
        get('/m', headers: const [(name: 'Cache-Control', value: 'max-stale')]),
      ),
      isA<CacheMiss>(),
    );
  });

  test('a stored no-cache response always revalidates', () {
    put(
      cache,
      get('/n'),
      ok(
        headers: const [
          (name: 'Cache-Control', value: 'no-cache'),
          (name: 'ETag', value: '"1"'),
        ],
      ),
    );
    expect(cache.lookup(get('/n')), isA<CacheRevalidate>());
  });

  group('refresh', () {
    test('a 304 updates headers and restarts freshness', () {
      final e = put(
        cache,
        get('/r'),
        ok(
          headers: const [
            (name: 'Cache-Control', value: 'max-age=10'),
            (name: 'ETag', value: '"1"'),
            (name: 'X-Old', value: 'a'),
          ],
        ),
      )!;
      now = now.add(const Duration(seconds: 20));
      cache.refresh(
        e,
        (
          version: '1.1',
          status: 304,
          reason: 'Not Modified',
          headers: const [
            (name: 'Cache-Control', value: 'max-age=100'),
            (name: 'Content-Length', value: '0'),
            (name: 'X-New', value: 'b'),
          ],
        ),
        requestTime: now,
        responseTime: now,
      );
      expect(e.isFresh(now), isTrue);
      expect(e.lifetime, const Duration(seconds: 100));
      expect(headerValue(e.head.headers, 'x-new'), 'b');
      expect(headerValue(e.head.headers, 'x-old'), 'a');
      expect(headerValue(e.head.headers, 'content-length'), '5');
      expect(e.head.status, 200);
    });

    test("a 304 never changes the stored body's description", () {
      final e = put(
        cache,
        get('/page'),
        ok(
          headers: const [
            (name: 'Cache-Control', value: 'max-age=0'),
            (name: 'ETag', value: '"1"'),
            (name: 'Content-Type', value: 'text/html'),
            (name: 'Content-Language', value: 'en'),
            (name: 'Content-Location', value: '/old'),
          ],
        ),
      )!;
      // What Dart's HttpServer sends for a bare 304.
      cache.refresh(
        e,
        (
          version: '1.1',
          status: 304,
          reason: 'Not Modified',
          headers: const [
            (name: 'content-type', value: 'text/plain; charset=utf-8'),
            (name: 'content-language', value: 'pt'),
            (name: 'content-length', value: '0'),
            (name: 'Content-Location', value: '/new'),
            (name: 'Cache-Control', value: 'max-age=30'),
          ],
        ),
        requestTime: now,
        responseTime: now,
      );
      expect(headerValue(e.head.headers, 'content-type'), 'text/html');
      expect(headerValue(e.head.headers, 'content-language'), 'en');
      expect(headerValue(e.head.headers, 'content-length'), '5');
      expect(headerValue(e.head.headers, 'content-location'), '/new');
      expect(headerValue(e.head.headers, 'cache-control'), 'max-age=30');
    });

    test("a 304's Set-Cookie is never stored", () {
      final e = put(cache, get('/sc'), ok())!;
      cache.refresh(
        e,
        (
          version: '1.1',
          status: 304,
          reason: '',
          headers: const [
            (name: 'Set-Cookie', value: 'sid=secret'),
            (name: 'X-New', value: '1'),
          ],
        ),
        requestTime: now,
        responseTime: now,
      );
      expect(headerValue(e.head.headers, 'set-cookie'), isNull);
      expect(headerValue(e.head.headers, 'x-new'), '1');
    });

    test('isRepresentationField', () {
      for (final n in [
        'Content-Type',
        'content-encoding',
        'Content-Length',
        'Content-Range',
        'Content-Disposition',
        'Transfer-Encoding',
        'Trailer',
      ]) {
        expect(HttpCache.isRepresentationField(n), isTrue, reason: n);
      }
      for (final n in ['Content-Location', 'ETag', 'Cache-Control', 'Date']) {
        expect(HttpCache.isRepresentationField(n), isFalse, reason: n);
      }
    });

    test('a 304 turning no-store drops the entry', () {
      final e = put(cache, get('/r'), ok())!;
      cache.refresh(
        e,
        (
          version: '1.1',
          status: 304,
          reason: '',
          headers: const [(name: 'Cache-Control', value: 'no-store')],
        ),
        requestTime: now,
        responseTime: now,
      );
      expect(cache.stats.entries, 0);
    });

    test('refreshing an evicted entry is a no-op', () {
      final e = put(cache, get('/r'), ok())!;
      cache.clear();
      cache.refresh(
        e,
        (version: '1.1', status: 304, reason: '', headers: const []),
        requestTime: now,
        responseTime: now,
      );
      expect(cache.stats.entries, 0);
    });
  });

  group('limits', () {
    test('per-cache LRU eviction', () {
      final one = put(cache, get('/1'), ok())!.size;
      final c = make(maxBytes: one * 2);
      put(c, get('/1'), ok());
      put(c, get('/2'), ok());
      c.lookup(get('/1')); // /1 now most recent
      put(c, get('/3'), ok());
      expect(c.lookup(get('/1')), isA<CacheHit>());
      expect(c.lookup(get('/2')), isA<CacheMiss>());
      expect(c.lookup(get('/3')), isA<CacheHit>());
      expect(c.stats.bytes, lessThanOrEqualTo(one * 2));
    });

    test('a shared budget evicts across caches', () {
      final one = put(cache, get('/1'), ok())!.size;
      final budget = HttpCacheBudget(one * 2);
      final a = make(budget: budget);
      final b2 = make(budget: budget);
      put(a, get('/a'), ok());
      put(b2, get('/b'), ok());
      expect(budget.usedBytes, one * 2);
      put(b2, get('/c'), ok());
      // The globally oldest entry (in the other cache) went first.
      expect(a.lookup(get('/a')), isA<CacheMiss>());
      expect(b2.lookup(get('/b')), isA<CacheHit>());
      expect(budget.usedBytes, one * 2);
      b2.clear();
      expect(budget.usedBytes, 0);
    });

    test('refresh re-counts a changed size against the budget', () {
      final budget = HttpCacheBudget(1 << 20);
      final c = make(budget: budget);
      final e = put(c, get('/r'), ok())!;
      final before = budget.usedBytes;
      c.refresh(
        e,
        (
          version: '1.1',
          status: 304,
          reason: '',
          headers: [(name: 'X-Big', value: 'x' * 500)],
        ),
        requestTime: now,
        responseTime: now,
      );
      expect(budget.usedBytes, before + e.size - before);
      expect(c.stats.bytes, budget.usedBytes);
    });
  });

  test('invalidate and clear', () {
    put(cache, get('/a'), ok());
    put(cache, get('/b'), ok());
    cache.invalidate(HttpCache.keyFor(get('/a')));
    cache.invalidate('nothing');
    expect(cache.lookup(get('/a')), isA<CacheMiss>());
    expect(cache.stats.entries, 1);
    cache.clear();
    expect(cache.stats.entries, 0);
    expect(cache.stats.bytes, 0);
  });

  test('stats counters', () {
    cache
      ..recordHit()
      ..recordMiss()
      ..recordMiss()
      ..recordRevalidated()
      ..recordBypass();
    final s = cache.stats;
    expect([s.hits, s.misses, s.revalidated, s.bypassed], [1, 2, 1, 1]);
  });

  group('stale-if-error', () {
    late HttpCacheEntry e;
    setUp(() {
      e = put(
        cache,
        get('/s'),
        ok(
          headers: const [
            (name: 'Cache-Control', value: 'max-age=10, stale-if-error=30'),
          ],
        ),
      )!;
    });

    test('within the window of the response directive', () {
      now = now.add(const Duration(seconds: 30));
      expect(cache.canServeStaleOnError(e, get('/s')), isTrue);
      now = now.add(const Duration(seconds: 20));
      expect(cache.canServeStaleOnError(e, get('/s')), isFalse);
    });

    test('the request directive takes precedence', () {
      now = now.add(const Duration(seconds: 30));
      expect(
        cache.canServeStaleOnError(
          e,
          get(
            '/s',
            headers: const [(name: 'Cache-Control', value: 'stale-if-error=5')],
          ),
        ),
        isFalse,
      );
    });

    test('without the directive: never', () {
      final plain = put(cache, get('/p'), ok())!;
      expect(cache.canServeStaleOnError(plain, get('/p')), isFalse);
    });
  });
}
