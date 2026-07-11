@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// Issues a GET to `127.0.0.1:$port$path` while presenting [host] in the Host
/// header, so host/domain/subdomain routing can be exercised over loopback.
Future<String> getWithHost(int port, String path, String host) async {
  final client = HttpClient();
  try {
    final request = await client.get('127.0.0.1', port, path);
    request.headers.set(HttpHeaders.hostHeader, host);
    final response = await request.close();
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

HandlerService named(String name, {String mount = '/'}) => HandlerService(
  name: name,
  mount: mount,
  handler: (_) async => HubResponse.text(name),
);

void main() {
  group('host / domain / subdomain routing', () {
    late OmnyHub hub;

    setUp(() async {
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      );
      await hub.route(HostRule('api.example.com'), named('api-host'));
      await hub.route(HostRule('www.example.com'), named('www-host'));
      await hub.route(SubdomainRule('admin'), named('admin-sub'));
      await hub.start();
    });

    tearDown(() => hub.stop());

    test('routes by Host header', () async {
      expect(await getWithHost(hub.port!, '/', 'api.example.com'), 'api-host');
      expect(await getWithHost(hub.port!, '/', 'www.example.com'), 'www-host');
    });

    test('routes by subdomain', () async {
      expect(await getWithHost(hub.port!, '/', 'admin.other.com'), 'admin-sub');
    });

    test('unmatched host returns 404', () async {
      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.get('127.0.0.1', hub.port!, '/');
      req.headers.set(HttpHeaders.hostHeader, 'unknown.test');
      final res = await req.close();
      expect(res.statusCode, 404);
    });
  });

  group('path / header / auth-state routing', () {
    late OmnyHub hub;
    late String base;

    setUp(() async {
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        // Middleware that promotes a caller to a principal from X-Role.
        middleware: [
          (inner) => (req) async {
            final role = req.header('x-role');
            if (role != null) {
              req.principal = Principal(id: 'caller', roles: {role});
            }
            return inner(req);
          },
        ],
      );

      // Longest-prefix path routing.
      await hub.registerService(named('root', mount: '/'));
      await hub.registerService(named('api', mount: '/api'));
      await hub.registerService(named('apiV1', mount: '/api/v1'));

      // Header-based canary at higher priority.
      await hub.route(
        PathRule('/app') & const HeaderRule('x-canary', equals: 'true'),
        named('canary'),
        priority: 10,
      );
      await hub.registerService(named('stable', mount: '/app'));

      // Auth-state routing: admins get a different handler on the same path.
      await hub.route(
        PathRule('/data') & AuthStateRule.hasRole('admin'),
        named('admin-data'),
        priority: 10,
      );
      await hub.route(PathRule('/data'), named('public-data'));

      await hub.start();
      base = 'http://127.0.0.1:${hub.port}';
    });

    tearDown(() => hub.stop());

    test('longest path prefix wins', () async {
      expect((await http.get(Uri.parse('$base/api/v1/x'))).body, 'apiV1');
      expect((await http.get(Uri.parse('$base/api/z'))).body, 'api');
      expect((await http.get(Uri.parse('$base/elsewhere'))).body, 'root');
    });

    test('header selects the canary route', () async {
      expect((await http.get(Uri.parse('$base/app'))).body, 'stable');
      final canary = await http.get(
        Uri.parse('$base/app'),
        headers: {'x-canary': 'true'},
      );
      expect(canary.body, 'canary');
    });

    test('auth state selects the admin route', () async {
      expect((await http.get(Uri.parse('$base/data'))).body, 'public-data');
      final admin = await http.get(
        Uri.parse('$base/data'),
        headers: {'x-role': 'admin'},
      );
      expect(admin.body, 'admin-data');
      final user = await http.get(
        Uri.parse('$base/data'),
        headers: {'x-role': 'user'},
      );
      expect(user.body, 'public-data');
    });
  });

  group('custom Router strategy', () {
    test('a hub-level custom router changes selection', () async {
      final hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        router: _FixedRouter('winner'),
      );
      await hub.registerService(named('loser', mount: '/'));
      await hub.registerService(named('winner', mount: '/'));
      await hub.start();
      addTearDown(hub.stop);

      final res = await http.get(Uri.parse('http://127.0.0.1:${hub.port}/x'));
      expect(res.body, 'winner');
    });
  });
}

/// A custom router that always selects the route with a fixed name if present.
class _FixedRouter implements Router {
  final String name;
  _FixedRouter(this.name);

  @override
  Route? resolve(RouteContext context, List<Route> routes) {
    for (final route in routes) {
      if (route.name == name && route.rule.matches(context)) return route;
    }
    return const RuleRouter().resolve(context, routes);
  }
}
