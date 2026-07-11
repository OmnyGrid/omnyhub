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

    test('requires seed domains or an allowDomain policy', () {
      expect(
        () => LetsEncryptTls(domains: [], cacheDir: cache.path),
        throwsA(isA<ValidationException>()),
      );
    });

    test('on-demand mode requires an email', () {
      expect(
        () => LetsEncryptTls(allowDomain: (_) => true, cacheDir: cache.path),
        throwsA(isA<ValidationException>()),
      );
    });

    group('dynamic / on-demand domains', () {
      late LetsEncryptTls tls;
      setUp(() {
        tls = LetsEncryptTls.onDemand(
          email: 'ops@example.com',
          allowDomain: (host) => host.endsWith('.example.com'),
          cacheDir: cache.path,
        );
      });

      test('supports SNI and reports on-demand', () {
        expect(tls.isOnDemand, isTrue);
        expect(tls.supportsSni, isTrue);
      });

      test(
        'accepts an async per-host email resolver instead of a fixed email',
        () {
          final resolved = LetsEncryptTls.onDemand(
            allowDomain: (host) => host.endsWith('.example.com'),
            emailResolver: (host) async => 'ops+$host@example.com',
            cacheDir: cache.path,
          );
          expect(resolved.isOnDemand, isTrue);
          expect(resolved.onDemandEmailResolver, isNotNull);
        },
      );

      test('on-demand requires a fixed email or a resolver', () {
        expect(
          () => LetsEncryptTls.onDemand(
            allowDomain: (_) => true,
            cacheDir: cache.path,
          ),
          throwsA(isA<ValidationException>()),
        );
      });

      test('policy allows matching hosts, rejects others', () {
        expect(tls.isAllowed('foo.example.com'), isTrue);
        expect(tls.isAllowed('BAR.example.com'), isTrue); // case-insensitive
        expect(tls.isAllowed('evil.test'), isFalse);
      });

      test('seed domains are always allowed even without a policy match', () {
        final seeded = LetsEncryptTls(
          domains: [Domain(name: 'fixed.org', email: 'a@b.c')],
          allowDomain: (host) => host.endsWith('.example.com'),
          onDemandEmail: 'ops@example.com',
          cacheDir: cache.path,
        );
        expect(seeded.isAllowed('fixed.org'), isTrue);
        expect(seeded.isAllowed('x.example.com'), isTrue);
        expect(seeded.isAllowed('other.net'), isFalse);
      });

      test(
        'contextFor returns null for an uncached host and does not throw',
        () {
          // No certificate yet; the SNI resolver returns the (null) default and
          // schedules background provisioning without blocking the handshake.
          expect(tls.contextFor('foo.example.com'), isNull);
          expect(tls.defaultContext, isNull);
        },
      );

      test('obtain rejects a disallowed host without provisioning', () async {
        expect(await tls.obtain('evil.test'), isFalse);
      });

      test('a single fixed domain does not use SNI', () {
        final single = LetsEncryptTls.forDomain(
          'only.example.com',
          'ops@example.com',
          cacheDir: cache.path,
        );
        expect(single.supportsSni, isFalse);
      });
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
