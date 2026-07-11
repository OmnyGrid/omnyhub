import 'dart:convert';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

HubRequest get req => HubRequest(
  method: 'GET',
  uri: Uri.parse('http://h/'),
  protocol: TransportProtocol.http,
);

void main() {
  group('envelope helpers', () {
    test('successEnvelope', () async {
      final res = successEnvelope({'k': 'v'}, statusCode: 201);
      expect(res.statusCode, 201);
      expect(jsonDecode(await res.readAsString()), {
        'success': true,
        'data': {'k': 'v'},
      });
    });

    test('errorEnvelope', () async {
      final res = errorEnvelope('bad', 'nope', statusCode: 422);
      expect(res.statusCode, 422);
      expect(jsonDecode(await res.readAsString()), {
        'success': false,
        'error': {'code': 'bad', 'message': 'nope'},
      });
    });
  });

  group('mapErrors', () {
    test('maps a matched error to a response', () async {
      final handler = mapErrors((e, _) {
        if (e is FormatException) return errorEnvelope('format', e.message);
        return null;
      })((_) async => throw const FormatException('boom'));
      final res = await handler(req);
      expect(res.statusCode, 400);
      expect(jsonDecode(await res.readAsString()), {
        'success': false,
        'error': {'code': 'format', 'message': 'boom'},
      });
    });

    test('rethrows when the mapper returns null', () async {
      final handler = mapErrors((_, _) => null)(
        (_) async => throw StateError('x'),
      );
      expect(() => handler(req), throwsStateError);
    });

    test('passes through successful responses', () async {
      final handler = mapErrors((_, _) => null)(
        (_) async => HubResponse.text('fine'),
      );
      expect((await handler(req)).statusCode, 200);
    });
  });
}
