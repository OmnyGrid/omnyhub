@TestOn('vm')
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// A stand-in ACME [TlsProvider] that exercises the hub's TLS orchestration —
/// challenge-middleware auto-mount, provision-before-bind, and renewal rebind —
/// without contacting a real certificate authority. It serves a real
/// [SecurityContext] from the committed static fixtures.
class FakeAcmeTls implements TlsProvider {
  final StaticTls _static;
  bool provisioned = false;
  int provisionCount = 0;
  int renewCount = 0;
  bool nextRenew = false;

  FakeAcmeTls(this._static);

  @override
  SecurityContext securityContext() {
    if (!provisioned) throw const TlsException('not provisioned');
    return _static.securityContext();
  }

  @override
  Middleware get challengeMiddleware =>
      (inner) => (request) async {
        if (request.path.startsWith('/.well-known/acme-challenge/')) {
          return HubResponse.text('FAKE-TOKEN');
        }
        return inner(request);
      };

  @override
  bool get hotReloadable => true;

  @override
  Future<void> provision() async {
    provisionCount++;
    provisioned = true;
  }

  @override
  Future<bool> maybeRenew() async {
    renewCount++;
    final refresh = nextRenew;
    nextRenew = false;
    return refresh;
  }
}

void main() {
  group('OmnyHub auto-TLS orchestration', () {
    late OmnyHub hub;
    late FakeAcmeTls fake;

    IOClient tlsClient() =>
        IOClient(HttpClient()..badCertificateCallback = (_, _, _) => true);

    setUp(() async {
      fake = FakeAcmeTls(
        StaticTls.files(
          'test/support/certs/localhost.crt',
          'test/support/certs/localhost.key',
        ),
      );
      hub = OmnyHub(
        transports: [
          HttpTransport.http(address: '127.0.0.1', port: 0),
          HttpTransport.https(address: '127.0.0.1', port: 0, tls: fake),
        ],
        tlsRenewalInterval: Duration.zero, // drive renewal manually
      );
      await hub.registerService(
        HandlerService(
          name: 'root',
          handler: (_) async => HubResponse.text('ok'),
        ),
      );
      await hub.start();
    });

    tearDown(() => hub.stop());

    test('provisions before binding the HTTPS listener', () async {
      // start() succeeded and HTTPS serves, which is only possible if
      // provision() ran before securityContext() was demanded.
      expect(fake.provisioned, isTrue);
      expect(fake.provisionCount, 1);

      final client = tlsClient();
      addTearDown(client.close);
      final res = await client.get(
        Uri.parse('https://127.0.0.1:${hub.transports[1].port}/'),
      );
      expect(res.statusCode, 200);
      expect(res.body, 'ok');
    }, tags: ['tls']);

    test('mounts the ACME challenge on the plaintext transport', () async {
      final httpPort = hub.transports[0].port;
      final res = await http.get(
        Uri.parse('http://127.0.0.1:$httpPort/.well-known/acme-challenge/abc'),
      );
      expect(res.body, 'FAKE-TOKEN');
    });

    test(
      'renewTls rebinds the listener when a certificate refreshes',
      () async {
        fake.nextRenew = true;
        await hub.renewTls();
        expect(fake.renewCount, 1);

        // After the rebind the HTTPS listener still serves (on its new port).
        final client = tlsClient();
        addTearDown(client.close);
        final res = await client.get(
          Uri.parse('https://127.0.0.1:${hub.transports[1].port}/'),
        );
        expect(res.statusCode, 200);
      },
      tags: ['tls'],
    );

    test('no rebind when nothing refreshed', () async {
      final portBefore = hub.transports[1].port;
      await hub.renewTls(); // nextRenew stays false
      expect(hub.transports[1].port, portBefore);
    });
  });
}
