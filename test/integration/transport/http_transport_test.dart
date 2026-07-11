@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// A request handler that echoes request details, used across the transport
/// integration tests.
Future<HubResponse> echoHandler(HubRequest request) async {
  switch (request.method) {
    case 'POST':
      final body = await request.readAsString();
      return HubResponse.text(
        'echo:$body',
        headers: {'x-proto': request.protocol.name},
      );
    case 'GET':
      if (request.path == '/boom') {
        throw const NotFoundException(message: 'nope');
      }
      return HubResponse.json({
        'path': request.path,
        'proto': request.protocol.name,
        'remote': request.remoteAddress,
        'query': request.uri.queryParameters,
      });
    default:
      return HubResponse.text('method:${request.method}');
  }
}

/// Echoes WebSocket messages, prefixing text with `ws:` and reversing binary.
void echoUpgrade(Connection connection, HubRequest request) {
  connection.incoming.listen((message) {
    switch (message) {
      case TextMessage(:final data):
        connection.send(TextMessage('ws:$data'));
      case BinaryMessage(:final data):
        connection.send(BinaryMessage(data.reversed.toList()));
    }
  });
}

void main() {
  group('HttpTransport (plaintext)', () {
    late HttpTransport transport;
    late String baseUrl;

    setUp(() async {
      transport = HttpTransport.http(address: '127.0.0.1', port: 0);
      await transport.bind(onRequest: echoHandler, onUpgrade: echoUpgrade);
      baseUrl = 'http://127.0.0.1:${transport.port}';
    });

    tearDown(() => transport.close(force: true));

    test('binds an ephemeral port', () {
      expect(transport.port, greaterThan(0));
      expect(transport.isBound, isTrue);
      expect(transport.protocol, TransportProtocol.http);
      expect(transport.isSecure, isFalse);
    });

    test('GET returns a JSON body with request details', () async {
      final res = await http.get(Uri.parse('$baseUrl/hello?x=1'));
      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['path'], '/hello');
      expect(body['proto'], 'http');
      expect(body['remote'], '127.0.0.1');
      expect(body['query'], {'x': '1'});
    });

    test('POST echoes the request body', () async {
      final res = await http.post(Uri.parse('$baseUrl/echo'), body: 'payload');
      expect(res.statusCode, 200);
      expect(res.body, 'echo:payload');
      expect(res.headers['x-proto'], 'http');
    });

    test('a thrown HubException becomes a typed error response', () async {
      final res = await http.get(Uri.parse('$baseUrl/boom'));
      expect(res.statusCode, 404);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect((body['error'] as Map)['code'], ErrorCodes.notFound);
      expect((body['error'] as Map)['message'], 'nope');
    });

    test('binding twice throws', () async {
      expect(
        () => transport.bind(onRequest: echoHandler),
        throwsA(isA<TransportException>()),
      );
    });

    test('WebSocket upgrade echoes text and binary frames', () async {
      final conn = await WebSocketConnection.connect(
        Uri.parse('ws://127.0.0.1:${transport.port}/ws'),
      );
      final received = <Message>[];
      final sub = conn.incoming.listen(received.add);

      conn.send(const TextMessage('hello'));
      await _until(() => received.length == 1);
      expect(received.last, const TextMessage('ws:hello'));

      conn.send(BinaryMessage([1, 2, 3]));
      await _until(() => received.length == 2);
      expect(received.last, BinaryMessage([3, 2, 1]));

      await sub.cancel();
      await conn.close();
    });
  });

  group('HttpTransport (TLS)', () {
    late HttpTransport transport;
    late int port;

    setUp(() async {
      final tls = StaticTls.files(
        'test/support/certs/localhost.crt',
        'test/support/certs/localhost.key',
      );
      transport = HttpTransport.https(address: '127.0.0.1', port: 0, tls: tls);
      await transport.bind(onRequest: echoHandler, onUpgrade: echoUpgrade);
      port = transport.port;
    });

    tearDown(() => transport.close(force: true));

    test('serves HTTPS with the static certificate', () async {
      expect(transport.protocol, TransportProtocol.https);
      expect(transport.isSecure, isTrue);

      final client = IOClient(
        HttpClient()..badCertificateCallback = (_, _, _) => true,
      );
      addTearDown(() => client.close());

      final res = await client.get(Uri.parse('https://127.0.0.1:$port/secure'));
      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['proto'], 'https');
    }, tags: ['tls']);

    test('serves WSS with the static certificate', () async {
      final conn = await WebSocketConnection.connect(
        Uri.parse('wss://127.0.0.1:$port/ws'),
        onBadCertificate: (_, _, _) => true,
      );
      final first = conn.incoming.first;
      conn.send(const TextMessage('secure'));
      expect(await first, const TextMessage('ws:secure'));
      await conn.close();
    }, tags: ['tls']);
  });
}

/// Polls [condition] until true or a short timeout elapses.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!condition()) throw StateError('condition not met before timeout');
}
