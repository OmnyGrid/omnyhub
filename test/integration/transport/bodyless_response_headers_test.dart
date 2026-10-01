@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// `204 No Content` and `304 Not Modified` carry no content, so they must not
/// claim a `Content-Type` nobody set. `dart:io` adds `text/plain; charset=utf-8`
/// to every response by default (dart-lang/sdk#64442); a `304` labelled that
/// way can relabel a cached page for any cache in front of the hub.
void main() {
  late HttpTransport transport;
  late ServerSocket upstream;
  late OmnyHub gateway;

  /// The raw head the hub sends for `GET path` (lower-cased names).
  Future<Map<String, String>> head(int port, String path) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    s.write('GET $path HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n');
    final text = await s.cast<List<int>>().transform(latin1.decoder).join();
    final lines = text.split('\r\n\r\n').first.split('\r\n');
    return {
      'status': lines.first.split(' ')[1],
      for (final l in lines.skip(1))
        l.substring(0, l.indexOf(':')).toLowerCase(): l
            .substring(l.indexOf(':') + 1)
            .trim(),
    };
  }

  group('a HubResponse', () {
    setUp(() async {
      transport = HttpTransport.http(address: '127.0.0.1', port: 0);
      await transport.bind(
        onRequest: (r) async => switch (r.path) {
          '/304' => HubResponse(statusCode: 304, headers: {'etag': '"v1"'}),
          '/204' => HubResponse(statusCode: 204),
          '/304-typed' => HubResponse(
            statusCode: 304,
            headers: {'content-type': 'text/html'},
          ),
          _ => HubResponse(statusCode: 200, body: Stream.value([0x41])),
        },
        onUpgrade: (_, _) {},
      );
    });

    tearDown(() => transport.close(force: true));

    test('304 without a Content-Type gets none', () async {
      final h = await head(transport.port, '/304');
      printOnFailure('$h');
      expect(h['status'], '304');
      expect(h['etag'], '"v1"');
      expect(h['content-type'], isNull);
    });

    test('204 without a Content-Type gets none', () async {
      final h = await head(transport.port, '/204');
      expect(h['status'], '204');
      expect(h['content-type'], isNull);
    });

    test('an explicit Content-Type on a 304 is kept', () async {
      final h = await head(transport.port, '/304-typed');
      expect(h['content-type'], 'text/html');
    });

    test('other responses keep the existing default', () async {
      final h = await head(transport.port, '/200');
      expect(h['status'], '200');
      expect(h['content-type'], 'text/plain; charset=utf-8');
    });
  });

  group('ProxyService', () {
    setUp(() async {
      // An upstream that answers a clean 304: no Content-Type at all.
      upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((s) {
        s.listen((_) {
          s.write(
            'HTTP/1.1 304 Not Modified\r\nETag: "u1"\r\n'
            'Cache-Control: max-age=60\r\nConnection: close\r\n\r\n',
          );
          s.close();
        });
      });
      gateway = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      );
      await gateway.route(
        PathRule('/'),
        ProxyService(
          Upstream.uri('http://127.0.0.1:${upstream.port}'),
          name: 'up',
          mount: '/',
        ),
      );
      await gateway.start();
    });

    tearDown(() async {
      await gateway.stop();
      await upstream.close();
    });

    test("a relayed 304 doesn't gain a Content-Type", () async {
      final h = await head(gateway.port!, '/page');
      expect(h['status'], '304');
      expect(h['etag'], '"u1"');
      expect(h['cache-control'], 'max-age=60');
      expect(h['content-type'], isNull);
    });
  });
}
