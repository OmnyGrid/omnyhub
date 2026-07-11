// Runs a gateway that reverse-proxies to a local backend, alongside a local
// service (hybrid mode). Everything runs in-process over loopback.
//
// Run with: dart run example/reverse_proxy_example.dart
import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';

Future<void> main() async {
  // A backend the gateway will forward to.
  final backend = OmnyHub(
    transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
  );
  await backend.registerService(
    HandlerService(
      name: 'backend',
      handler: (r) async => HubResponse.text('backend handled ${r.path}'),
    ),
  );
  await backend.start();
  final backendBase = 'http://127.0.0.1:${backend.port}';

  // The gateway: a path-based reverse proxy + a local service, one port.
  final gateway = OmnyHub(
    transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
  );
  await gateway.route(
    PathRule('/api'),
    ProxyService(
      Upstream.uri(backendBase),
      name: 'api-proxy',
      mount: '/api',
      stripPrefix: '/api',
    ),
  );
  // Host-based gateway route (matched via the Host header).
  await gateway.route(
    HostRule('files.example.com'),
    ProxyService(Upstream.uri(backendBase), name: 'files-proxy'),
  );
  await gateway.registerService(
    HandlerService(
      name: 'health',
      mount: '/health',
      handler: (_) async => HubResponse.text('ok'),
    ),
  );
  await gateway.start();
  final base = 'http://127.0.0.1:${gateway.port}';
  print('Gateway on $base, proxying /api -> $backendBase');

  print(
    'GET /api/users  -> ${(await http.get(Uri.parse('$base/api/users'))).body}',
  );
  print(
    'GET /health     -> ${(await http.get(Uri.parse('$base/health'))).body}',
  );

  await gateway.stop();
  await backend.stop();
}
