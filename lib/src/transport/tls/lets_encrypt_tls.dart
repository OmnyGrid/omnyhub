import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_letsencrypt/shelf_letsencrypt.dart';

import '../../http/handler.dart';
import '../../http/hub_request.dart';
import '../../http/hub_response.dart';
import '../../shared/errors/hub_exception.dart';
import 'tls_provider.dart';

/// A [TlsProvider] that provisions and renews certificates automatically via
/// Let's Encrypt (ACME HTTP-01), backed by `package:shelf_letsencrypt`.
///
/// OmnyHub owns the server lifecycle, so this adapter does **not** bind its own
/// listeners (unlike `LetsEncrypt.startServer`). Instead it exposes:
///
/// * [challengeMiddleware] — the hub mounts this first on its plaintext (port
///   80) transport so the ACME CA's HTTP-01 validation requests are answered;
/// * [provision] — requests certificates for any domain that lacks a valid one
///   (the validation traffic hits the challenge middleware), then builds the
///   [SecurityContext];
/// * [maybeRenew] — renews certificates near expiry and reports whether the
///   context changed so the hub can rebind the HTTPS listener (hot reload).
///
/// > **Ports:** ACME HTTP-01 requires a reachable **port 80**; add an
/// > `HttpTransport.http(port: 80)` to the hub. The self-checks during renewal
/// > use [securePort].
/// >
/// > **Staging vs production:** [production] defaults to `false` (Let's Encrypt
/// > *staging*, whose certificates are browser-invalid but avoid the strict
/// > production rate limits). Set it to `true` only once issuance works.
class LetsEncryptTls implements TlsProvider {
  /// The domains to provision certificates for.
  final List<Domain> domains;

  /// The directory where account keys and certificates are cached.
  final String cacheDir;

  /// Whether to use the production ACME endpoint (`false` = staging).
  final bool production;

  /// The public HTTPS port, used by renewal self-checks.
  final int securePort;

  final CertificatesHandlerIO _certificates;
  final LetsEncrypt _letsEncrypt;
  SecurityContext? _context;

  LetsEncryptTls._(
    this.domains,
    this.cacheDir,
    this.production,
    this.securePort,
    this._certificates,
    this._letsEncrypt,
  );

  /// Creates an ACME provider for [domains], caching material under [cacheDir].
  factory LetsEncryptTls({
    required List<Domain> domains,
    required String cacheDir,
    bool production = false,
    int challengePort = 80,
    int securePort = 443,
  }) {
    if (domains.isEmpty) {
      throw const ValidationException('At least one domain is required');
    }
    final certificates = CertificatesHandlerIO(Directory(cacheDir));
    final letsEncrypt = LetsEncrypt(
      certificates,
      production: production,
      port: challengePort,
      securePort: securePort,
    );
    return LetsEncryptTls._(
      domains,
      cacheDir,
      production,
      securePort,
      certificates,
      letsEncrypt,
    );
  }

  /// Convenience constructor for a single [domain]/[email].
  factory LetsEncryptTls.forDomain(
    String domain,
    String email, {
    required String cacheDir,
    bool production = false,
    int challengePort = 80,
    int securePort = 443,
  }) => LetsEncryptTls(
    domains: [Domain(name: domain, email: email)],
    cacheDir: cacheDir,
    production: production,
    challengePort: challengePort,
    securePort: securePort,
  );

  @override
  SecurityContext securityContext() {
    final context = _context;
    if (context == null) {
      throw const TlsException(
        'TLS certificate not provisioned yet; call provision() first',
      );
    }
    return context;
  }

  @override
  bool get hotReloadable => true;

  @override
  Middleware get challengeMiddleware =>
      (inner) => (request) async {
        final path = request.path;
        if (LetsEncrypt.isACMEPath(path)) {
          return _adapt(
            _letsEncrypt.processACMEChallengeRequest(_toShelf(request)),
          );
        }
        if (LetsEncrypt.isSelfCheckPath(path)) {
          return _adapt(
            _letsEncrypt.processSelfCheckRequest(_toShelf(request)),
          );
        }
        return inner(request);
      };

  @override
  Future<void> provision() async {
    for (final domain in domains) {
      if (!_certificates.isHandledDomainCertificate(domain.name)) {
        final ok = await _letsEncrypt.requestCertificate(domain);
        if (!ok) {
          throw TlsException(
            'Failed to provision certificate for ${domain.name}',
          );
        }
      }
    }
    await _loadContext();
  }

  @override
  Future<bool> maybeRenew() async {
    var refreshed = false;
    for (final domain in domains) {
      final status = await _letsEncrypt.checkCertificate(
        domain,
        requestCertificate: true,
      );
      if (status.isOkRefreshed) refreshed = true;
    }
    if (refreshed) await _loadContext();
    return refreshed;
  }

  Future<void> _loadContext() async {
    final contexts = await _certificates.buildSecurityContexts(
      domains,
      allowUnresolvedDomain: true,
      loadAllHandledDomains: true,
    );
    if (contexts == null || contexts.isEmpty) {
      throw TlsException(
        'No certificates available for '
        '${domains.map((d) => d.name).join(', ')}',
      );
    }
    // Bind with the first domain's context. Multi-domain SNI selection is a
    // documented future enhancement.
    _context = contexts.values.first;
  }

  shelf.Request _toShelf(HubRequest request) =>
      shelf.Request(request.method, request.uri, headers: request.headers);

  HubResponse _adapt(shelf.Response response) => HubResponse(
    statusCode: response.statusCode,
    headers: response.headers,
    body: response.read(),
  );
}
