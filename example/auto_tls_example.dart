// Demonstrates TLS configuration. The runnable path uses a static certificate
// (the committed self-signed test fixture); the automatic Let's Encrypt path is
// shown in comments because it requires a public domain and reachable port 80.
//
// Run with: dart run example/auto_tls_example.dart
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub.dart';

Future<void> main() async {
  // --- Static certificate (runnable) --------------------------------------
  final hub = OmnyHub(
    transports: [
      HttpTransport.https(
        address: '127.0.0.1',
        port: 0,
        tls: StaticTls.files(
          'test/support/certs/localhost.crt',
          'test/support/certs/localhost.key',
        ),
      ),
    ],
  );
  await hub.registerService(
    HandlerService(
      name: 'root',
      handler: (_) async => HubResponse.text('secure hello'),
    ),
  );
  await hub.start();

  // A client that trusts the self-signed test certificate.
  final client = IOClient(
    HttpClient()..badCertificateCallback = (_, _, _) => true,
  );
  final res = await client.get(
    Uri.parse('https://127.0.0.1:${hub.transports.first.port}/'),
  );
  print('HTTPS (static cert) -> ${res.body}');
  client.close();
  await hub.stop();

  // --- Automatic Let's Encrypt (production, not run here) -----------------
  //
  // Add a plaintext transport on port 80 so ACME HTTP-01 challenges can be
  // answered, and an HTTPS transport whose TLS provider auto-provisions and
  // renews certificates. OmnyHub mounts the challenge middleware, provisions on
  // start, and hot-reloads the listener on renewal automatically.
  //
  //   final hub = OmnyHub(transports: [
  //     HttpTransport.http(port: 80),
  //     HttpTransport.https(port: 443, tls: LetsEncryptTls(
  //       domains: [Domain(name: 'api.example.com', email: 'ops@example.com')],
  //       cacheDir: '/var/lib/omnyhub/certs',
  //       production: true, // defaults to false (staging)
  //     )),
  //   ]);
  //   await hub.start();
}
