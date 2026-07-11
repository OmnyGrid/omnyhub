// Hosts several services on a single hub/port and exercises them over loopback.
//
// Run with: dart run example/service_hosting_example.dart
import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';

Future<void> main() async {
  final hub = OmnyHub(
    transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
  );

  // Three services, each mounted at its own path prefix, one port.
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
      handler: (_) async => HubResponse.text('requests_total 1'),
    ),
  );
  await hub.registerService(
    HandlerService(
      name: 'chat',
      mount: '/chat',
      handler: (_) async => HubResponse.text('connect a WebSocket'),
      onConnection: (conn, _) {
        conn.incoming.listen((m) {
          if (m is TextMessage) conn.send(TextMessage('echo: ${m.data}'));
        });
      },
    ),
  );

  await hub.start();
  final base = 'http://127.0.0.1:${hub.port}';
  print('Hub listening on $base');

  print(
    'GET /api/items    -> ${(await http.get(Uri.parse('$base/api/items'))).body}',
  );
  print(
    'GET /metrics      -> ${(await http.get(Uri.parse('$base/metrics'))).body}',
  );

  final ws = await WebSocketConnection.connect(
    Uri.parse('ws://127.0.0.1:${hub.port}/chat'),
  );
  final reply = ws.incoming.first;
  ws.send(const TextMessage('hello'));
  print('WS  /chat         -> ${await reply}');
  await ws.close();

  // Services can be added and removed at runtime.
  await hub.unregisterService('metrics');
  final gone = await http.get(Uri.parse('$base/metrics'));
  print('GET /metrics (removed) -> ${gone.statusCode}');

  await hub.stop();
}
