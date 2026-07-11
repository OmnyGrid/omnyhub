@TestOn('vm')
@Tags(['tls'])
library;

import 'dart:io';

import 'package:http/io_client.dart';
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// A fake SNI provider serving one real certificate, recording the hostnames
/// the resolver is consulted with. Exercises the transport's SNI binding path
/// (via MultiDomainSecureServer) without a certificate authority.
class FakeSni implements TlsProvider, SniTlsProvider {
  final SecurityContext _context;
  final bool useResolver;
  final List<String?> asked = [];

  FakeSni(this._context, {this.useResolver = true});

  @override
  bool get supportsSni => true;

  @override
  SecurityContext? get defaultContext => _context;

  @override
  SecurityContext? contextFor(String? host) {
    asked.add(host);
    return useResolver ? _context : null;
  }

  @override
  SecurityContext securityContext() => _context;

  @override
  Middleware? get challengeMiddleware => null;

  @override
  bool get hotReloadable => false;

  @override
  Future<void> provision() async {}

  @override
  Future<bool> maybeRenew() async => false;
}

SecurityContext localhostContext() => StaticTls.files(
  'test/support/certs/localhost.crt',
  'test/support/certs/localhost.key',
).securityContext();

/// Serves [body] over an SNI transport backed by [tls] and returns the response
/// of a single HTTPS GET. The client connects by hostname so it sends SNI (the
/// SNI listener requires it).
Future<String> serveAndGet(FakeSni tls, String body) async {
  final transport = HttpTransport.https(
    address: '127.0.0.1',
    port: 0,
    tls: tls,
  );
  await transport.bind(onRequest: (r) async => HubResponse.text(body));
  final client = IOClient(
    HttpClient()..badCertificateCallback = (_, _, _) => true,
  );
  try {
    final res = await client
        .get(Uri.parse('https://localhost:${transport.port}/'))
        .timeout(const Duration(seconds: 10));
    return res.body;
  } finally {
    client.close();
    await transport.close(force: true);
  }
}

void main() {
  test(
    'SNI transport serves per-host certs and falls back to the default',
    () async {
      // Resolver returns a certificate for the requested host.
      final resolved = FakeSni(localhostContext());
      expect(await serveAndGet(resolved, 'sni-ok'), 'sni-ok');
      // The resolver was consulted with the SNI host — the SNI path is live.
      expect(resolved.asked, contains('localhost'));

      // Resolver returns null; the transport serves the default context instead.
      final fallback = FakeSni(localhostContext(), useResolver: false);
      expect(await serveAndGet(fallback, 'default'), 'default');
    },
  );
}
