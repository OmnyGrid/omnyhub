import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('Json', () {
    test('asObject casts maps and rejects non-objects', () {
      expect(Json.asObject({'a': 1}), {'a': 1});
      expect(() => Json.asObject('nope'), throwsA(isA<ProtocolException>()));
    });

    test('requireString reads and validates', () {
      expect(Json.requireString({'k': 'v'}, 'k'), 'v');
      expect(
        () => Json.requireString({'k': 1}, 'k'),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => Json.requireString({}, 'k'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('optString honours fallback and null', () {
      expect(Json.optString({}, 'k'), isNull);
      expect(Json.optString({}, 'k', 'def'), 'def');
      expect(Json.optString({'k': 'v'}, 'k'), 'v');
      expect(
        () => Json.optString({'k': 3}, 'k'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('requireInt and optInt', () {
      expect(Json.requireInt({'n': 5}, 'n'), 5);
      expect(Json.optInt({}, 'n', 9), 9);
      expect(
        () => Json.requireInt({'n': 'x'}, 'n'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('optBool', () {
      expect(Json.optBool({}, 'b'), isFalse);
      expect(Json.optBool({}, 'b', fallback: true), isTrue);
      expect(Json.optBool({'b': true}, 'b'), isTrue);
      expect(
        () => Json.optBool({'b': 1}, 'b'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('timestamps parse to UTC', () {
      final t = Json.requireTimestamp({'t': '2026-01-02T03:04:05Z'}, 't');
      expect(t.isUtc, isTrue);
      expect(t.year, 2026);
      expect(Json.optTimestamp({}, 't'), isNull);
      expect(
        () => Json.requireTimestamp({'t': 'not-a-date'}, 't'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('optStringMap and optStringList', () {
      expect(Json.optStringMap({}, 'm'), isEmpty);
      expect(
        Json.optStringMap({
          'm': {'a': 1, 'b': 'c'},
        }, 'm'),
        {'a': '1', 'b': 'c'},
      );
      expect(Json.optStringList({}, 'l'), isEmpty);
      expect(
        Json.optStringList({
          'l': [1, 'two'],
        }, 'l'),
        ['1', 'two'],
      );
    });
  });
}
