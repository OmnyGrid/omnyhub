@TestOn('vm')
@Tags(['tls'])
library;

import 'dart:io';

import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/temp_dir.dart';

/// Echoes WebSocket text frames, prefixing with `ws:`.
void wsEcho(Connection conn, HubRequest req) {
  conn.incoming.listen((m) {
    if (m is TextMessage) conn.send(TextMessage('ws:${m.data}'));
  });
}

void main() {
  test('reloads when file contents change (byte-compare)', () async {
    final dir = await TempDir.create();
    addTearDown(dir.cleanup);
    final certPath = dir.resolve('cert.pem');
    final keyPath = dir.resolve('key.pem');
    final certBytes = File(
      'test/support/certs/localhost.crt',
    ).readAsBytesSync();
    final keyBytes = File('test/support/certs/localhost.key').readAsBytesSync();
    File(certPath).writeAsBytesSync(certBytes);
    File(keyPath).writeAsBytesSync(keyBytes);

    final tls = ReloadableFileTls.files(certPath, keyPath);
    expect(tls.hotReloadable, isTrue);

    // No content change => no reload.
    expect(await tls.maybeRenew(), isFalse);

    // A cert-manager rewrites the cert (a leading PEM comment => new bytes,
    // still parseable). Byte-compare detects it even at the same size class.
    File(certPath).writeAsBytesSync([...'# renewed\n'.codeUnits, ...certBytes]);
    expect(await tls.maybeRenew(), isTrue);
    // Idempotent afterwards.
    expect(await tls.maybeRenew(), isFalse);
  });

  test('directory layout resolves fullchain/privkey', () async {
    final dir = await TempDir.create();
    addTearDown(dir.cleanup);
    File(
      'test/support/certs/localhost.crt',
    ).copySync(dir.resolve('fullchain.pem'));
    File(
      'test/support/certs/localhost.key',
    ).copySync(dir.resolve('privkey.pem'));
    final tls = ReloadableFileTls.directory(dir.path);
    expect(tls.securityContext(), isNotNull);
  });

  test(
    'gap-free rebind keeps a live connection alive and the port stable',
    () async {
      final tls = StaticTls.files(
        'test/support/certs/localhost.crt',
        'test/support/certs/localhost.key',
      );
      final transport = HttpTransport.https(
        address: '127.0.0.1',
        port: 0,
        tls: tls,
      );
      await transport.bind(
        onRequest: (_) async => HubResponse.text('ok'),
        onUpgrade: wsEcho,
      );
      addTearDown(() => transport.close(force: true));
      final port = transport.port;

      // Open a live WSS connection before the swap.
      final live = await WebSocketConnection.connect(
        Uri.parse('wss://127.0.0.1:$port/ws'),
        onBadCertificate: (_, _, _) => true,
      );

      // Renew: bind a fresh shared listener on the same port, drain the old.
      await transport.rebind();
      expect(transport.port, port); // same port, no gap

      // The pre-existing connection still works (drained gracefully).
      final echoed = live.incoming.first;
      live.send(const TextMessage('alive'));
      expect(await echoed, const TextMessage('ws:alive'));
      await live.close();

      // New connections work on the renewed listener.
      final client = IOClient(
        HttpClient()..badCertificateCallback = (_, _, _) => true,
      );
      addTearDown(client.close);
      final res = await client.get(Uri.parse('https://127.0.0.1:$port/'));
      expect(res.body, 'ok');
    },
  );
}
