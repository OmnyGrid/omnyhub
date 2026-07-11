@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('OmnyHub multi-service hosting', () {
    late OmnyHub hub;
    late String base;

    setUp(() async {
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      );
      await hub.registerService(
        HandlerService(
          name: 'api',
          mount: '/api',
          handler: (r) async =>
              HubResponse.json({'service': 'api', 'path': r.path}),
        ),
      );
      await hub.registerService(
        HandlerService(
          name: 'metrics',
          mount: '/metrics',
          handler: (_) async => HubResponse.text('requests 1'),
        ),
      );
      await hub.registerService(
        HandlerService(
          name: 'echo-ws',
          mount: '/ws',
          handler: (_) async => HubResponse.text('use a websocket'),
          onConnection: (conn, _) {
            conn.incoming.listen((m) {
              if (m is TextMessage) conn.send(TextMessage('echo:${m.data}'));
            });
          },
        ),
      );
      await hub.start();
      base = 'http://127.0.0.1:${hub.port}';
    });

    tearDown(() => hub.stop());

    test('routes to the correct service by mount prefix', () async {
      final api = await http.get(Uri.parse('$base/api/items'));
      expect(jsonDecode(api.body), {'service': 'api', 'path': '/api/items'});

      final metrics = await http.get(Uri.parse('$base/metrics'));
      expect(metrics.body, 'requests 1');
    });

    test('unmatched paths return 404 with an error envelope', () async {
      final res = await http.get(Uri.parse('$base/nope'));
      expect(res.statusCode, 404);
      expect(
        (jsonDecode(res.body)['error'] as Map)['code'],
        ErrorCodes.noRoute,
      );
    });

    test('WebSocket service on the same port echoes', () async {
      final conn = await WebSocketConnection.connect(
        Uri.parse('ws://127.0.0.1:${hub.port}/ws'),
      );
      final first = conn.incoming.first;
      conn.send(const TextMessage('hi'));
      expect(await first, const TextMessage('echo:hi'));
      await conn.close();
    });

    test('services can be added and removed at runtime', () async {
      expect((await http.get(Uri.parse('$base/live'))).statusCode, 404);

      await hub.registerService(
        HandlerService(
          name: 'live',
          mount: '/live',
          handler: (_) async => HubResponse.text('now here'),
        ),
      );
      expect((await http.get(Uri.parse('$base/live'))).body, 'now here');

      await hub.unregisterService('live');
      expect((await http.get(Uri.parse('$base/live'))).statusCode, 404);
    });

    test('duplicate service names are rejected', () {
      expect(
        () => hub.registerService(
          HandlerService(name: 'api', handler: (_) async => HubResponse.ok()),
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('OmnyHub lifecycle and middleware', () {
    test('runs middleware and reports lifecycle state', () async {
      var seen = 0;
      final hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        middleware: [
          (inner) => (req) async {
            seen++;
            final res = await inner(req);
            return res;
          },
        ],
      );
      await hub.registerService(
        HandlerService(
          name: 'root',
          handler: (_) async => HubResponse.text('hi'),
        ),
      );
      expect(hub.isRunning, isFalse);
      await hub.start();
      expect(hub.isRunning, isTrue);

      await http.get(Uri.parse('http://127.0.0.1:${hub.port}/'));
      expect(seen, 1);

      expect(() => hub.use((h) => h), throwsStateError);
      expect(hub.start, throwsStateError);

      await hub.stop();
      expect(hub.isRunning, isFalse);
    });
  });
}
