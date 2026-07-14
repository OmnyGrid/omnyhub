@TestOn('vm')
library;

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

const String _app = 'https://app.test';

/// CORS on a real hub, over a real socket.
///
/// The interesting cases are the *failures*. A browser can only read a response
/// it is allowed to read, so a `401`, `404` or `500` without
/// `Access-Control-Allow-Origin` reaches the app as an opaque network error and
/// the real cause is invisible. Those responses are rendered by the hub's
/// `errorMapper`, which sits above ordinary middleware — which is precisely why
/// `cors()` goes in `outerMiddleware`.
void main() {
  late OmnyHub hub;
  late HttpTransport transport;
  late String baseUrl;

  Future<void> startHub({bool outer = true}) async {
    transport = HttpTransport.http(address: '127.0.0.1', port: 0);
    final corsMiddleware = cors(allowedOrigins: [_app], allowCredentials: true);
    hub = OmnyHub(
      transports: [transport],
      outerMiddleware: outer ? [corsMiddleware] : const [],
      middleware: outer ? const [] : [corsMiddleware],
      authenticator: BearerTokenAuthenticator({
        'good-token': Principal(id: 'alice'),
      }),
    );
    await hub.registerService(
      RouterService(name: 'api', mount: '/api')
        ..get('/api/ok', (r, p) async => HubResponse.json({'ok': true}))
        ..get('/api/boom', (r, p) async => throw StateError('kaboom')),
    );
    await hub.start();
    baseUrl = 'http://127.0.0.1:${transport.port}';
  }

  tearDown(() => hub.stop());

  group('mounted in outerMiddleware', () {
    setUp(() => startHub());

    test('a preflight is answered without credentials', () async {
      // A browser never sends Authorization on a preflight. Before the outer
      // layer existed, the global authenticator would 401 this — making the hub
      // uncallable from a browser at all.
      final res = await http.Response.fromStream(
        await http.Client().send(
          http.Request('OPTIONS', Uri.parse('$baseUrl/api/ok'))
            ..headers.addAll({
              'origin': _app,
              'access-control-request-method': 'GET',
              'access-control-request-headers': 'authorization',
            }),
        ),
      );

      expect(res.statusCode, 204);
      expect(res.headers['access-control-allow-origin'], _app);
      expect(
        res.headers['access-control-allow-headers'],
        contains('authorization'),
      );
    });

    test('an authenticated request carries the CORS headers', () async {
      final res = await http.get(
        Uri.parse('$baseUrl/api/ok'),
        headers: {'origin': _app, 'authorization': 'Bearer good-token'},
      );

      expect(res.statusCode, 200);
      expect(res.headers['access-control-allow-origin'], _app);
      expect(res.headers['access-control-allow-credentials'], 'true');
    });

    test('a 401 is readable by the browser', () async {
      final res = await http.get(
        Uri.parse('$baseUrl/api/ok'),
        headers: {'origin': _app, 'authorization': 'Bearer wrong-token'},
      );

      expect(res.statusCode, 401);
      expect(
        res.headers['access-control-allow-origin'],
        _app,
        reason: 'without this the browser sees a network error, not a 401',
      );
    });

    test('a 404 is readable by the browser', () async {
      final res = await http.get(
        Uri.parse('$baseUrl/nowhere'),
        headers: {'origin': _app, 'authorization': 'Bearer good-token'},
      );

      expect(res.statusCode, 404);
      expect(res.headers['access-control-allow-origin'], _app);
    });

    test('a 500 is readable by the browser', () async {
      final res = await http.get(
        Uri.parse('$baseUrl/api/boom'),
        headers: {'origin': _app, 'authorization': 'Bearer good-token'},
      );

      expect(res.statusCode, 500);
      expect(res.headers['access-control-allow-origin'], _app);
    });

    test('a disallowed origin is not granted access', () async {
      final res = await http.get(
        Uri.parse('$baseUrl/api/ok'),
        headers: {
          'origin': 'https://evil.test',
          'authorization': 'Bearer good-token',
        },
      );

      expect(res.statusCode, 200);
      expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('a non-browser client sees no CORS headers at all', () async {
      final res = await http.get(
        Uri.parse('$baseUrl/api/ok'),
        headers: {'authorization': 'Bearer good-token'},
      );

      expect(res.statusCode, 200);
      expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
      expect(res.headers.containsKey('vary'), isFalse);
    });
  });

  group('mounted in ordinary middleware', () {
    setUp(() => startHub(outer: false));

    test(
      'success responses are stamped — the supported-but-limited case',
      () async {
        final res = await http.get(
          Uri.parse('$baseUrl/api/ok'),
          headers: {'origin': _app, 'authorization': 'Bearer good-token'},
        );

        expect(res.statusCode, 200);
        expect(res.headers['access-control-allow-origin'], _app);
      },
    );

    test(
      'but a 401 is NOT stamped: the authenticator rejects above it',
      () async {
        final res = await http.get(
          Uri.parse('$baseUrl/api/ok'),
          headers: {'origin': _app, 'authorization': 'Bearer wrong-token'},
        );

        expect(res.statusCode, 401);
        expect(
          res.headers.containsKey('access-control-allow-origin'),
          isFalse,
          reason: 'this is the whole reason outerMiddleware exists',
        );
      },
    );
  });
}
