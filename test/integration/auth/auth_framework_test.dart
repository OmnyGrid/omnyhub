@TestOn('vm')
library;

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

HandlerService whoAmI(String name, String mount) => HandlerService(
  name: name,
  mount: mount,
  handler: (r) async => HubResponse.text(r.principal?.id ?? 'anon'),
);

Future<http.Response> get(
  String url, {
  String? token,
  Map<String, String>? headers,
}) => http.get(
  Uri.parse(url),
  headers: {if (token != null) 'authorization': 'Bearer $token', ...?headers},
);

void main() {
  group('per-service authenticators', () {
    late OmnyHub hub;
    late String base;

    setUp(() async {
      final x = BearerTokenAuthenticator({'x-token': Principal(id: 'x-user')});
      final y = BearerTokenAuthenticator({'y-token': Principal(id: 'y-user')});
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      );
      await hub.registerService(whoAmI('a', '/a'), authenticator: x);
      await hub.registerService(whoAmI('b', '/b'), authenticator: x);
      await hub.registerService(whoAmI('c', '/c'), authenticator: y);
      await hub.start();
      base = 'http://127.0.0.1:${hub.port}';
    });
    tearDown(() => hub.stop());

    test('services A and B use handler X, C uses handler Y', () async {
      expect((await get('$base/a', token: 'x-token')).body, 'x-user');
      expect((await get('$base/b', token: 'x-token')).body, 'x-user');
      expect((await get('$base/c', token: 'y-token')).body, 'y-user');
    });

    test("a service rejects the other service's token", () async {
      expect((await get('$base/a', token: 'y-token')).statusCode, 401);
      expect((await get('$base/c', token: 'x-token')).statusCode, 401);
    });
  });

  group('global AuthCoordinator decisions', () {
    late OmnyHub hub;
    late String base;

    setUp(() async {
      final global = BearerTokenAuthenticator({
        'g-token': Principal(id: 'g-user'),
      });
      final perService = BearerTokenAuthenticator({
        's-token': Principal(id: 's-user'),
      });
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        authCoordinator: CoordinatorFn((req, route) async {
          if (req.header('x-block') != null) {
            return const Blocked(TooManyRequestsException('rate limited'));
          }
          if (req.path.startsWith('/public')) return const Anonymous();
          if (route.authenticator != null) return const Delegate();
          final p = await global.authenticate(req);
          return p != null ? Authenticated(p) : const Anonymous();
        }),
      );
      await hub.registerService(whoAmI('public', '/public'));
      await hub.registerService(
        whoAmI('svc', '/svc'),
        authenticator: perService,
      );
      await hub.registerService(whoAmI('global', '/global'));
      await hub.start();
      base = 'http://127.0.0.1:${hub.port}';
    });
    tearDown(() => hub.stop());

    test('bypass (Anonymous)', () async {
      expect((await get('$base/public')).body, 'anon');
    });

    test('delegate to per-service authenticator', () async {
      expect((await get('$base/svc', token: 's-token')).body, 's-user');
    });

    test('global authentication', () async {
      expect((await get('$base/global', token: 'g-token')).body, 'g-user');
    });

    test('pre-check block yields 429', () async {
      final res = await get('$base/public', headers: {'x-block': '1'});
      expect(res.statusCode, 429);
    });
  });

  group('per-service authorizer', () {
    test('overrides the hub-wide authorizer', () async {
      final hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      );
      await hub.registerService(
        whoAmI('admin', '/admin'),
        authenticator: BearerTokenAuthenticator({
          'admin': Principal(id: 'a', roles: {'admin'}),
          'user': Principal(id: 'u', roles: {'user'}),
        }),
        authorizer: const RoleBasedAuthorizer(anyRoles: {'admin'}),
      );
      await hub.start();
      addTearDown(hub.stop);
      final base = 'http://127.0.0.1:${hub.port}';

      expect((await get('$base/admin', token: 'admin')).body, 'a');
      expect((await get('$base/admin', token: 'user')).statusCode, 403);
    });
  });

  group('back-compat: hub-wide authenticator still works', () {
    test('global authenticator path unchanged', () async {
      final hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        authenticator: BearerTokenAuthenticator({'t': Principal(id: 'global')}),
      );
      await hub.registerService(whoAmI('root', '/'));
      await hub.start();
      addTearDown(hub.stop);
      final base = 'http://127.0.0.1:${hub.port}';
      expect((await get('$base/', token: 't')).body, 'global');
      expect((await get('$base/')).body, 'anon');
    });
  });
}
