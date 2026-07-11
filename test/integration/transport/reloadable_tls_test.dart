@TestOn('vm')
@Tags(['tls'])
library;

import 'dart:io';

import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/temp_dir.dart';

void main() {
  test('reloads the certificate when the files change and rebinds', () async {
    final dir = await TempDir.create();
    addTearDown(dir.cleanup);
    final certPath = dir.resolve('cert.pem');
    final keyPath = dir.resolve('key.pem');
    await File('test/support/certs/localhost.crt').copy(certPath);
    await File('test/support/certs/localhost.key').copy(keyPath);

    final tls = ReloadableFileTls.files(certPath, keyPath);
    final hub = OmnyHub(
      transports: [
        HttpTransport.https(address: '127.0.0.1', port: 0, tls: tls),
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
    addTearDown(hub.stop);

    IOClient client() =>
        IOClient(HttpClient()..badCertificateCallback = (_, _, _) => true);

    final before = client();
    final r1 = await before.get(
      Uri.parse('https://127.0.0.1:${hub.transports.first.port}/'),
    );
    expect(r1.body, 'ok');
    before.close();

    // No change yet => no rebind.
    expect(await tls.maybeRenew(), isFalse);

    // Simulate a cert-manager rotating the files (mtime bumps) and renew.
    final newer = DateTime.now().add(const Duration(seconds: 2));
    File(certPath).setLastModifiedSync(newer);
    File(keyPath).setLastModifiedSync(newer);
    expect(await tls.maybeRenew(), isTrue);

    await hub.renewTls();

    final after = client();
    final r2 = await after.get(
      Uri.parse('https://127.0.0.1:${hub.transports.first.port}/'),
    );
    expect(r2.statusCode, 200);
    after.close();
  });

  test('directory layout resolves fullchain/privkey', () async {
    final dir = await TempDir.create();
    addTearDown(dir.cleanup);
    await File(
      'test/support/certs/localhost.crt',
    ).copy(dir.resolve('fullchain.pem'));
    await File(
      'test/support/certs/localhost.key',
    ).copy(dir.resolve('privkey.pem'));
    final tls = ReloadableFileTls.directory(dir.path);
    expect(tls.securityContext(), isNotNull);
    expect(tls.hotReloadable, isTrue);
  });
}
