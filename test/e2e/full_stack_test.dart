@TestOn('vm')
@Tags(['tls'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Polls [condition] until true or a timeout elapses.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!condition()) throw StateError('condition not met within $timeout');
}

void main() {
  late TestCluster cluster;

  setUp(() async => cluster = await TestCluster.start());
  tearDown(() async => cluster.dispose());

  test('multi-service hosting over HTTP and HTTPS on one cluster', () async {
    final overHttp = await http.get(
      Uri.parse('http://127.0.0.1:${cluster.httpPort}/api/x'),
    );
    expect(jsonDecode(overHttp.body), {'service': 'api'});

    final tlsHttp = IOClient(
      HttpClient()..badCertificateCallback = acceptTestCert,
    );
    addTearDown(tlsHttp.close);
    final overHttps = await tlsHttp.get(
      Uri.parse('https://127.0.0.1:${cluster.httpsPort}/api/x'),
    );
    expect(overHttps.statusCode, 200);
    expect(jsonDecode(overHttps.body), {'service': 'api'});
  });

  test(
    'reverse proxy forwards HTTP and WebSocket through the gateway',
    () async {
      final proxied = await http.get(
        Uri.parse('http://127.0.0.1:${cluster.httpPort}/proxy/thing'),
      );
      expect(jsonDecode(proxied.body), {
        'from': 'backend',
        'path': '/proxy/thing',
      });

      final ws = await WebSocketConnection.connect(
        Uri.parse('ws://127.0.0.1:${cluster.httpPort}/proxy'),
      );
      final first = ws.incoming.first;
      ws.send(const TextMessage('ping'));
      expect(await first, const TextMessage('backend:ping'));
      await ws.close();
    },
  );

  test(
    'node registers, is discovered, and answers an RPC end-to-end',
    () async {
      final node = await cluster.startNode(
        'e2e-worker',
        capabilities: {'compute'},
        onRequest: (action, payload) async => {'pong': payload['ping']},
      );
      await waitFor(() => node.isReady);
      await waitFor(() => cluster.gateway.nodes.isNotEmpty);

      expect(
        cluster.gateway.discover(capability: 'compute').single.id.value,
        'e2e-worker',
      );

      final response = await cluster.gateway.request(
        NodeId('e2e-worker'),
        'echo',
        payload: {'ping': 42},
      );
      expect(response.ok, isTrue);
      expect(response.payload['pong'], 42);
    },
  );
}
