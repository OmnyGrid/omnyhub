import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('CacheControl.parse', () {
    test('names are lower-cased; values unquoted; first wins', () {
      final cc = CacheControl.parse(
        'Public, MAX-AGE=60, private="Set-Cookie, X", max-age=5, no-cache',
      );
      expect(cc.directives, {
        'public': null,
        'max-age': '60',
        'private': 'Set-Cookie, X',
        'no-cache': null,
      });
      expect(cc.isPublic, isTrue);
      expect(cc.isPrivate, isTrue);
      expect(cc.noCache, isTrue);
      expect(cc.seconds('max-age'), 60);
    });

    test('escaped quotes and stray spaces', () {
      final cc = CacheControl.parse(r'a="x\"y" , b = 3 ,, c');
      expect(cc.directives['a'], 'x"y');
      expect(cc.directives['b'], '3');
      expect(cc.has('c'), isTrue);
    });

    test('null or empty yields nothing', () {
      expect(CacheControl.parse(null).directives, isEmpty);
      expect(CacheControl.parse('').directives, isEmpty);
    });

    test('malformed or negative deltas read as absent', () {
      final cc = CacheControl.parse('max-age=abc, s-maxage=-1, x');
      expect(cc.seconds('max-age'), isNull);
      expect(cc.seconds('s-maxage'), isNull);
      expect(cc.seconds('x'), isNull);
      expect(cc.seconds('missing'), isNull);
    });

    test('flags', () {
      expect(CacheControl.parse('no-store').noStore, isTrue);
      expect(CacheControl.parse('must-revalidate').mustRevalidate, isTrue);
      expect(CacheControl.parse('proxy-revalidate').mustRevalidate, isTrue);
      expect(CacheControl.parse('only-if-cached').onlyIfCached, isTrue);
    });

    test('of() combines repeated fields', () {
      final cc = CacheControl.of(const [
        (name: 'Cache-Control', value: 'public'),
        (name: 'cache-control', value: 'max-age=9'),
      ]);
      expect(cc.seconds('max-age'), 9);
      expect(cc.isPublic, isTrue);
    });
  });

  group('freshnessLifetime', () {
    final t = DateTime.utc(2026, 10, 1, 12);
    Duration? life(List<HeaderField> h, {Duration? ttl}) =>
        freshnessLifetime(h, defaultTtl: ttl, responseTime: t);

    test('s-maxage beats max-age', () {
      expect(
        life(const [(name: 'Cache-Control', value: 'max-age=10, s-maxage=20')]),
        const Duration(seconds: 20),
      );
      expect(
        life(const [(name: 'Cache-Control', value: 'max-age=10')]),
        const Duration(seconds: 10),
      );
    });

    test('no-cache grants zero', () {
      expect(
        life(const [(name: 'Cache-Control', value: 'no-cache, max-age=99')]),
        Duration.zero,
      );
    });

    test('Expires minus Date', () {
      expect(
        life([
          (name: 'Date', value: formatHttpDate(t)),
          (
            name: 'Expires',
            value: formatHttpDate(t.add(const Duration(minutes: 5))),
          ),
        ]),
        const Duration(minutes: 5),
      );
    });

    test('Expires without Date uses the response time', () {
      expect(
        life([
          (
            name: 'Expires',
            value: formatHttpDate(t.add(const Duration(seconds: 30))),
          ),
        ]),
        const Duration(seconds: 30),
      );
    });

    test('a past or invalid Expires means already expired', () {
      expect(
        life([
          (
            name: 'Expires',
            value: formatHttpDate(t.subtract(const Duration(hours: 1))),
          ),
        ]),
        Duration.zero,
      );
      expect(life(const [(name: 'Expires', value: '0')]), Duration.zero);
    });

    test('falls back to the default TTL, else none', () {
      expect(life(const []), isNull);
      expect(
        life(const [], ttl: const Duration(minutes: 1)),
        const Duration(minutes: 1),
      );
      expect(
        life(const [
          (name: 'Cache-Control', value: 'public'),
        ], ttl: const Duration(seconds: 7)),
        const Duration(seconds: 7),
      );
    });
  });

  test('parseHttpDate / formatHttpDate round-trip; bad input is null', () {
    final t = DateTime.utc(1994, 11, 6, 8, 49, 37);
    expect(formatHttpDate(t), 'Sun, 06 Nov 1994 08:49:37 GMT');
    expect(parseHttpDate(formatHttpDate(t)), t);
    expect(parseHttpDate('yesterday'), isNull);
    expect(parseHttpDate(null), isNull);
  });

  test('hasValidator', () {
    expect(hasValidator(const [(name: 'ETag', value: '"a"')]), isTrue);
    expect(hasValidator(const [(name: 'Last-Modified', value: 'x')]), isTrue);
    expect(hasValidator(const []), isFalse);
  });
}
