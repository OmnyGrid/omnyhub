@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  late OmnyHub backend;
  late OmnyHub gateway;
  late String backendBase;
  late String gatewayBase;

  setUp(() async {
    // The upstream: echoes request details and runs a WebSocket echo.
    backend = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await backend.registerService(
      HandlerService(
        name: 'echo',
        handler: (r) async {
          final body = await r.readAsString();
          return HubResponse.json(
            {
              'method': r.method,
              'path': r.path,
              'query': r.uri.query,
              'body': body,
              'xff': r.header('x-forwarded-for'),
              'xfproto': r.header('x-forwarded-proto'),
              'xfhost': r.header('x-forwarded-host'),
              'host': r.header('host'),
              'custom': r.header('x-custom'),
            },
            headers: {'x-backend': 'yes'},
          );
        },
        onConnection: (conn, _) {
          conn.incoming.listen((m) {
            if (m is TextMessage) conn.send(TextMessage('backend:${m.data}'));
          });
        },
      ),
    );
    await backend.start();
    backendBase = 'http://127.0.0.1:${backend.port}';

    // The gateway: proxies + one local service (hybrid).
    gateway = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await gateway.route(
      PathRule('/svc'),
      ProxyService(Upstream.uri(backendBase), name: 'svc', mount: '/svc'),
    );
    await gateway.route(
      PathRule('/api'),
      ProxyService(
        Upstream.uri(backendBase),
        name: 'api',
        mount: '/api',
        stripPrefix: '/api',
      ),
    );
    await gateway.route(
      PathRule('/ws'),
      ProxyService(Upstream.uri(backendBase), name: 'ws', mount: '/ws'),
    );
    await gateway.route(
      HostRule('app.example.com'),
      ProxyService(Upstream.uri(backendBase), name: 'host', mount: '/'),
    );
    await gateway.route(
      PathRule('/dead'),
      ProxyService(
        Upstream.uri('http://127.0.0.1:1'),
        name: 'dead',
        mount: '/dead',
      ),
    );
    await gateway.registerService(
      HandlerService(
        name: 'local',
        mount: '/local',
        handler: (_) async => HubResponse.text('local-response'),
      ),
    );
    await gateway.start();
    gatewayBase = 'http://127.0.0.1:${gateway.port}';
  });

  tearDown(() async {
    await gateway.stop();
    await backend.stop();
  });

  test('forwards path and query unchanged', () async {
    final res = await http.get(Uri.parse('$gatewayBase/svc/things?q=1'));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect(res.statusCode, 200);
    expect(body['path'], '/svc/things');
    expect(body['query'], 'q=1');
    expect(res.headers['x-backend'], 'yes'); // response header passes through
  });

  test('stripPrefix rewrites the forwarded path', () async {
    final res = await http.get(Uri.parse('$gatewayBase/api/things'));
    expect((jsonDecode(res.body) as Map)['path'], '/things');
  });

  test('streams the request body upstream', () async {
    final res = await http.post(
      Uri.parse('$gatewayBase/svc/echo'),
      body: 'payload-bytes',
    );
    expect((jsonDecode(res.body) as Map)['body'], 'payload-bytes');
  });

  test('injects X-Forwarded-* and forwards custom headers', () async {
    final res = await http.get(
      Uri.parse('$gatewayBase/svc/x'),
      headers: {'x-custom': 'kept'},
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect(body['xfproto'], 'http');
    expect(body['xfhost'], '127.0.0.1');
    expect(body['xff'], isNotNull);
    expect(body['custom'], 'kept');
    // Host header is rewritten to the upstream authority.
    expect(body['host'], '127.0.0.1:${backend.port}');
  });

  test('host-based gateway routing', () async {
    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.get('127.0.0.1', gateway.port!, '/anything');
    req.headers.set(HttpHeaders.hostHeader, 'app.example.com');
    final res = await req.close();
    final body =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(body['path'], '/anything');
    expect(body['xfhost'], 'app.example.com');
  });

  test('hybrid: local service coexists with proxies', () async {
    expect(
      (await http.get(Uri.parse('$gatewayBase/local'))).body,
      'local-response',
    );
  });

  test('unreachable upstream yields 502', () async {
    final res = await http.get(Uri.parse('$gatewayBase/dead'));
    expect(res.statusCode, 502);
  });

  test('forwards WebSocket upgrades and pipes frames', () async {
    final conn = await WebSocketConnection.connect(
      Uri.parse('ws://127.0.0.1:${gateway.port}/ws'),
    );
    final first = conn.incoming.first;
    conn.send(const TextMessage('ping'));
    expect(await first, const TextMessage('backend:ping'));
    await conn.close();
  });
}
