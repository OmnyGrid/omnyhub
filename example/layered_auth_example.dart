// Demonstrates per-service + global authentication and host/regexp routing:
//   * services A and B authenticate with handler X, service C with handler Y;
//   * a global AuthCoordinator decides bypass / delegate / block (pre-check);
//   * a HostPatternRule routes by a regexp over the host, combined with a path.
//
// Run with: dart run example/layered_auth_example.dart
import 'dart:io';

import 'package:omnyhub/omnyhub.dart';

Future<void> main() async {
  final x = BearerTokenAuthenticator({'x-tok': Principal(id: 'x-user')});
  final y = BearerTokenAuthenticator({'y-tok': Principal(id: 'y-user')});

  final hub = OmnyHub(
    transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    // Global coordinator: block suspicious requests, bypass /health, otherwise
    // delegate to each service's own authenticator.
    authCoordinator: CoordinatorFn((req, route) async {
      if (req.header('x-attack') != null) {
        return const Blocked(TooManyRequestsException('blocked'));
      }
      if (req.path == '/health') return const Anonymous();
      return const Delegate();
    }),
  );

  Future<HubResponse> whoAmI(HubRequest r) async =>
      HubResponse.text(r.principal?.id ?? 'anon');

  await hub.registerService(
    HandlerService(
      name: 'health',
      mount: '/health',
      handler: (_) async => HubResponse.text('ok'),
    ),
  );
  await hub.registerService(
    HandlerService(name: 'a', mount: '/a', handler: whoAmI),
    authenticator: x,
  );
  await hub.registerService(
    HandlerService(name: 'b', mount: '/b', handler: whoAmI),
    authenticator: x,
  );
  await hub.registerService(
    HandlerService(name: 'c', mount: '/c', handler: whoAmI),
    authenticator: y,
  );
  // Host regexp routing (matched via the Host header), combined with a path.
  await hub.route(
    HostPatternRule(RegExp(r'^(dev|stg)\.example\.com$')) & PathRule('/api'),
    HandlerService(
      name: 'staging-api',
      handler: (_) async => HubResponse.text('staging api'),
    ),
  );

  await hub.start();
  final base = 'http://127.0.0.1:${hub.port}';
  final client = HttpClient();

  Future<String> get(
    String path, {
    String? token,
    String? host,
    Map<String, String>? extra,
  }) async {
    final req = await client.getUrl(Uri.parse('$base$path'));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
    extra?.forEach(req.headers.set);
    final res = await req.close();
    final body = await res.transform(const SystemEncoding().decoder).join();
    return '${res.statusCode} $body';
  }

  print('/health (bypass)        -> ${await get('/health')}');
  print('/a with X token         -> ${await get('/a', token: 'x-tok')}');
  print('/c with Y token         -> ${await get('/c', token: 'y-tok')}');
  print('/a with wrong token     -> ${await get('/a', token: 'y-tok')}');
  print(
    '/health with x-attack   -> ${await get('/health', extra: {'x-attack': '1'})}',
  );
  print(
    'host regexp + /api      -> ${await get('/api/x', host: 'dev.example.com')}',
  );

  client.close();
  await hub.stop();
}
