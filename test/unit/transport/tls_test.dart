import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/temp_dir.dart';

HubRequest req(String path, {Map<String, String> headers = const {}}) =>
    HubRequest(
      method: 'GET',
      uri: Uri.parse('http://api.example.com$path'),
      protocol: TransportProtocol.http,
      headers: headers,
    );

void main() {
  group('StaticTls', () {
    test('loads a certificate and is not hot-reloadable', () async {
      final tls = StaticTls.files(
        'test/support/certs/localhost.crt',
        'test/support/certs/localhost.key',
      );
      expect(tls.securityContext(), isNotNull);
      expect(tls.hotReloadable, isFalse);
      expect(tls.challengeMiddleware, isNull);
      expect(await tls.maybeRenew(), isFalse);
      await tls.provision(); // no-op, should not throw
    });

    test('invalid certificate paths raise TlsException', () {
      expect(
        () => StaticTls.files('nope.crt', 'nope.key'),
        throwsA(isA<TlsException>()),
      );
    });
  });

  group('LetsEncryptTls', () {
    late TempDir cache;

    setUp(() async {
      cache = await TempDir.create();
    });
    tearDown(() => cache.cleanup());

    test('requires at least one domain', () {
      expect(
        () => LetsEncryptTls(domains: [], cacheDir: cache.path),
        throwsA(isA<ValidationException>()),
      );
    });

    test('securityContext throws before provisioning', () {
      final tls = LetsEncryptTls.forDomain(
        'example.com',
        'ops@example.com',
        cacheDir: cache.path,
      );
      expect(tls.securityContext, throwsA(isA<TlsException>()));
      expect(tls.hotReloadable, isTrue);
    });

    test('challenge middleware answers ACME and self-check paths', () async {
      final tls = LetsEncryptTls.forDomain(
        'example.com',
        'ops@example.com',
        cacheDir: cache.path,
      );
      final mw = tls.challengeMiddleware;

      // Unknown challenge token (nothing provisioned) => 404 from the ACME
      // handler, proving the middleware is wired to shelf_letsencrypt.
      final acme = await mw((r) async => HubResponse.text('passthrough'))(
        req('/.well-known/acme-challenge/xyz'),
      );
      expect(acme.statusCode, 404);

      // Self-check path answers 200 OK.
      final check = await mw((r) async => HubResponse.text('passthrough'))(
        req('/.well-known/check/self'),
      );
      expect(check.statusCode, 200);

      // Any other path passes through to the inner handler.
      final other = await mw((r) async => HubResponse.text('passthrough'))(
        req('/api/items'),
      );
      expect(await other.readAsString(), 'passthrough');
    });
  });
}
