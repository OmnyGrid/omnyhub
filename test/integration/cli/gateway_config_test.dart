@TestOn('vm')
library;

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub_cli.dart';
import 'package:test/test.dart';

void main() {
  test('builds a gateway that proxies path routes to a backend', () async {
    // A real backend to proxy to.
    final backend = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await backend.registerService(
      HandlerService(
        name: 'backend',
        handler: (r) async => HubResponse.text('backend:${r.path}'),
      ),
    );
    await backend.start();
    addTearDown(backend.stop);

    final gateway = await buildGateway({
      'listen': [
        {'protocol': 'http', 'address': '127.0.0.1', 'port': 0},
      ],
      'routes': [
        {
          'path': '/api',
          'target': 'http://127.0.0.1:${backend.port}',
          'stripPrefix': '/api',
        },
      ],
    });
    await gateway.start();
    addTearDown(gateway.stop);

    final res = await http.get(
      Uri.parse('http://127.0.0.1:${gateway.port}/api/things'),
    );
    expect(res.statusCode, 200);
    expect(res.body, 'backend:/things');
  });

  test('rejects an empty listen list', () {
    expect(
      () => buildGateway({'listen': [], 'routes': []}),
      throwsA(isA<ValidationException>()),
    );
  });

  test('rejects a route without path or host', () {
    expect(
      () => buildGateway({
        'listen': [
          {'protocol': 'http', 'port': 0},
        ],
        'routes': [
          {'target': 'http://localhost:1'},
        ],
      }),
      throwsA(isA<ValidationException>()),
    );
  });

  test('rejects an unknown protocol', () {
    expect(
      () => buildGateway({
        'listen': [
          {'protocol': 'gopher', 'port': 0},
        ],
      }),
      throwsA(isA<ValidationException>()),
    );
  });
}
