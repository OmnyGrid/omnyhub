@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('Bearer auth + role authorizer', () {
    late OmnyHub hub;
    late String base;

    setUp(() async {
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        authenticator: BearerTokenAuthenticator({
          'admin-token': Principal(id: 'admin', roles: {'admin'}),
          'user-token': Principal(id: 'user', roles: {'user'}),
        }),
        authorizer: const RoleBasedAuthorizer(anyRoles: {'admin'}),
      );
      await hub.registerService(
        HandlerService(
          name: 'root',
          handler: (r) async => HubResponse.text('welcome ${r.principal?.id}'),
        ),
      );
      await hub.start();
      base = 'http://127.0.0.1:${hub.port}';
    });

    tearDown(() => hub.stop());

    Future<http.Response> get({String? token}) => http.get(
      Uri.parse('$base/'),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    );

    test('valid admin token is allowed', () async {
      final res = await get(token: 'admin-token');
      expect(res.statusCode, 200);
      expect(res.body, 'welcome admin');
    });

    test('missing credentials are forbidden (anonymous denied)', () async {
      expect((await get()).statusCode, 403);
    });

    test('invalid credentials are unauthorized', () async {
      expect((await get(token: 'garbage')).statusCode, 401);
    });

    test('authenticated but unauthorized role is forbidden', () async {
      expect((await get(token: 'user-token')).statusCode, 403);
    });
  });

  group('Basic auth', () {
    test('authenticates and exposes the principal', () async {
      final hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        authenticator: BasicAuthAuthenticator({'alice': 'pw'}),
      );
      await hub.registerService(
        HandlerService(
          name: 'root',
          handler: (r) async => HubResponse.text(r.principal?.id ?? 'anon'),
        ),
      );
      await hub.start();
      addTearDown(hub.stop);

      final ok = await http.get(
        Uri.parse('http://127.0.0.1:${hub.port}/'),
        headers: {
          'authorization': 'Basic ${base64.encode(utf8.encode('alice:pw'))}',
        },
      );
      expect(ok.body, 'alice');

      final anon = await http.get(Uri.parse('http://127.0.0.1:${hub.port}/'));
      expect(anon.body, 'anon');
    });
  });

  group('WebSocket authentication', () {
    late OmnyHub hub;

    setUp(() async {
      hub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
        authenticator: BearerTokenAuthenticator({
          'ok': Principal(id: 'u', roles: {'admin'}),
        }),
        authorizer: const RoleBasedAuthorizer(anyRoles: {'admin'}),
      );
      await hub.registerService(
        HandlerService(
          name: 'ws',
          mount: '/ws',
          handler: (_) async => HubResponse.ok(),
          onConnection: (conn, _) {
            conn.incoming.listen((m) {
              if (m is TextMessage) conn.send(TextMessage('ok:${m.data}'));
            });
          },
        ),
      );
      await hub.start();
    });

    tearDown(() => hub.stop());

    test('authorized upgrade echoes', () async {
      final conn = await WebSocketConnection.connect(
        Uri.parse('ws://127.0.0.1:${hub.port}/ws'),
        headers: {'authorization': 'Bearer ok'},
      );
      final first = conn.incoming.first;
      conn.send(const TextMessage('hi'));
      expect(await first, const TextMessage('ok:hi'));
      await conn.close();
    });

    test('unauthorized upgrade is closed without echo', () async {
      final conn = await WebSocketConnection.connect(
        Uri.parse('ws://127.0.0.1:${hub.port}/ws'),
      );
      final messages = <Message>[];
      conn.incoming.listen(messages.add);
      conn.send(const TextMessage('hi'));
      await conn.done.timeout(const Duration(seconds: 5));
      expect(messages, isEmpty);
    });
  });
}
