import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_letsencrypt/shelf_letsencrypt.dart';

import '../../http/handler.dart';
import '../../http/hub_request.dart';
import '../../http/hub_response.dart';
import '../../shared/errors/hub_exception.dart';
import 'tls_provider.dart';

/// Decides whether an on-demand certificate may be requested for [host].
/// May be asynchronous (e.g. a per-tenant database or API lookup).
typedef DomainPolicy = FutureOr<bool> Function(String host);

/// Resolves the ACME contact email to use for an on-demand certificate for
/// [host]. May be asynchronous (e.g. a database lookup per tenant).
typedef EmailResolver = FutureOr<String> Function(String host);

/// A [TlsProvider] that provisions and renews certificates automatically via
/// Let's Encrypt (ACME HTTP-01), backed by `package:shelf_letsencrypt`.
///
/// OmnyHub owns the server lifecycle, so this adapter does **not** bind its own
/// listeners (unlike `LetsEncrypt.startServer`). Instead it exposes:
///
/// * [challengeMiddleware] — the hub mounts this first on its plaintext (port
///   80) transport so the ACME CA's HTTP-01 validation requests are answered;
/// * [provision] — requests certificates for any seed [domains] that lack a
///   valid one, then builds their [SecurityContext]s;
/// * [contextFor] — the SNI resolver: returns the certificate for a requested
///   host, and (in on-demand mode) kicks off provisioning for allowed hosts it
///   does not yet have;
/// * [maybeRenew] — renews certificates near expiry.
///
/// ## Dynamic / on-demand domains
///
/// Passing an [allowDomain] policy (plus an [onDemandEmail]) enables **on-demand
/// issuance**: any host the policy allows gets a certificate provisioned the
/// first time it is seen, without the developer listing it in code. Because
/// certificates are served via SNI from a live cache, `foo.example.com` and
/// `bar.example.com` "just work" as they start being used:
///
/// ```dart
/// final tls = LetsEncryptTls(
///   onDemandEmail: 'ops@example.com',
///   allowDomain: (host) => host.endsWith('.example.com'),
///   cacheDir: '/var/lib/omnyhub/certs',
///   production: true,
/// );
/// final hub = OmnyHub(transports: [
///   HttpTransport.http(port: 80),                 // ACME HTTP-01 challenges
///   HttpTransport.https(port: 443, tls: tls),     // SNI, on-demand certs
/// ]);
/// ```
///
/// The first TLS handshake for an allowed, not-yet-provisioned host triggers
/// background issuance (validated via the challenge on port 80); the certificate
/// is served on the next connection. You can also pre-provision a host at any
/// time with [obtain] (e.g. at tenant sign-up).
///
/// > **Ports:** ACME HTTP-01 requires a reachable **port 80**; add an
/// > `HttpTransport.http(port: 80)`. Renewal self-checks use [securePort].
/// >
/// > **Staging vs production:** [production] defaults to `false` (Let's Encrypt
/// > *staging*, whose certificates are browser-invalid but avoid the strict
/// > production rate limits). Set it to `true` only once issuance works.
class LetsEncryptTls implements TlsProvider, SniTlsProvider {
  /// Seed domains provisioned up front on [provision].
  final List<Domain> domains;

  /// The directory where account keys and certificates are cached.
  final String cacheDir;

  /// Whether to use the production ACME endpoint (`false` = staging).
  final bool production;

  /// The public HTTPS port, used by renewal self-checks.
  final int securePort;

  /// Policy allowing on-demand certificates for hosts it returns `true` for.
  /// `null` disables on-demand issuance (only [domains] are served).
  final DomainPolicy? allowDomain;

  /// The fixed contact email used for on-demand certificates. `null` when an
  /// [onDemandEmailResolver] is supplied instead.
  final String? onDemandEmail;

  /// Resolves the contact email per host for on-demand certificates, allowing a
  /// different email for each domain. Takes precedence over [onDemandEmail].
  final EmailResolver? onDemandEmailResolver;

  /// Whether a missing certificate may be requested from the CA.
  ///
  /// When `false`, only certificates already present in [cacheDir] are served
  /// and the CA is never contacted — for a deployment whose certificates are
  /// provisioned out-of-band.
  final bool autoIssue;

  /// How much validity a certificate must have left to be kept; below this it
  /// is renewed by [maybeRenew]. Defaults to 5 days.
  ///
  /// This is the safety margin, and it is only as good as the renewal cadence
  /// that checks it: a certificate is renewed at most one
  /// `OmnyHub.tlsRenewalInterval` (12h by default) after dropping below
  /// [renewBefore], so keep it comfortably larger than that interval. Raise it
  /// when a failed renewal needs room for several retries before the
  /// certificate actually expires — Let's Encrypt's own advice is to renew with
  /// about a third of the lifetime remaining (30 of 90 days).
  ///
  /// A certificate that is still valid keeps being served while it renews in
  /// the background; only an *expired* one is withheld.
  final Duration renewBefore;

  /// Hosts a previous [obtain] rejected, so a repeated TLS handshake does not
  /// re-invoke a (possibly expensive, possibly async) [allowDomain] policy.
  /// Bounded: an SNI flood of random hostnames must not grow it without limit.
  static const _maxDenied = 1024;

  final CertificatesHandlerIO _certificates;
  final LetsEncrypt _letsEncrypt;
  final Map<String, SecurityContext> _contexts = {};
  final Map<String, Future<bool>> _inFlight = {};
  final Set<String> _denied = {};
  SecurityContext? _default;

  LetsEncryptTls._(
    this.domains,
    this.cacheDir,
    this.production,
    this.securePort,
    this.allowDomain,
    this.onDemandEmail,
    this.onDemandEmailResolver,
    this.autoIssue,
    this.renewBefore,
    this._certificates,
    this._letsEncrypt,
  );

  /// Creates an ACME provider.
  ///
  /// Provide seed [domains] (provisioned on start), an [allowDomain] policy for
  /// on-demand issuance, or both. On-demand issuance requires a contact email:
  /// a fixed [onDemandEmail], or an [onDemandEmailResolver] to resolve it per
  /// host (e.g. a per-tenant lookup).
  ///
  /// Set [autoIssue] to `false` to serve only certificates already cached in
  /// [cacheDir], never contacting the CA. Use [renewBefore] to widen the margin
  /// in which a certificate is renewed.
  factory LetsEncryptTls({
    List<Domain> domains = const [],
    DomainPolicy? allowDomain,
    String? onDemandEmail,
    EmailResolver? onDemandEmailResolver,
    required String cacheDir,
    bool production = false,
    bool autoIssue = true,
    Duration renewBefore = const Duration(days: 5),
    int challengePort = 80,
    int securePort = 443,
  }) {
    if (domains.isEmpty && allowDomain == null) {
      throw const ValidationException(
        'Provide seed domains and/or an allowDomain policy',
      );
    }
    if (allowDomain != null &&
        (onDemandEmail == null || onDemandEmail.isEmpty) &&
        onDemandEmailResolver == null) {
      throw const ValidationException(
        'onDemandEmail or onDemandEmailResolver is required when '
        'allowDomain is set',
      );
    }
    if (renewBefore <= Duration.zero) {
      throw const ValidationException('renewBefore must be positive');
    }
    final certificates = CertificatesHandlerIO(Directory(cacheDir));
    final letsEncrypt = LetsEncrypt(
      certificates,
      production: production,
      port: challengePort,
      securePort: securePort,
    )..minCertificateValidityTime = renewBefore;
    return LetsEncryptTls._(
      domains,
      cacheDir,
      production,
      securePort,
      allowDomain,
      onDemandEmail,
      onDemandEmailResolver,
      autoIssue,
      renewBefore,
      certificates,
      letsEncrypt,
    );
  }

  /// Convenience constructor for a single fixed [domain]/[email].
  factory LetsEncryptTls.forDomain(
    String domain,
    String email, {
    required String cacheDir,
    bool production = false,
    bool autoIssue = true,
    Duration renewBefore = const Duration(days: 5),
    int challengePort = 80,
    int securePort = 443,
  }) => LetsEncryptTls(
    domains: [Domain(name: domain, email: email)],
    cacheDir: cacheDir,
    production: production,
    autoIssue: autoIssue,
    renewBefore: renewBefore,
    challengePort: challengePort,
    securePort: securePort,
  );

  /// Convenience constructor for on-demand issuance of any host matching
  /// [allowDomain].
  ///
  /// Supply a fixed [email], or an [emailResolver] to choose the contact address
  /// per host (e.g. a different email for each tenant domain); exactly one is
  /// required.
  factory LetsEncryptTls.onDemand({
    required DomainPolicy allowDomain,
    required String cacheDir,
    String? email,
    EmailResolver? emailResolver,
    List<Domain> domains = const [],
    bool production = false,
    bool autoIssue = true,
    Duration renewBefore = const Duration(days: 5),
    int challengePort = 80,
    int securePort = 443,
  }) => LetsEncryptTls(
    domains: domains,
    allowDomain: allowDomain,
    onDemandEmail: email,
    onDemandEmailResolver: emailResolver,
    cacheDir: cacheDir,
    production: production,
    autoIssue: autoIssue,
    renewBefore: renewBefore,
    challengePort: challengePort,
    securePort: securePort,
  );

  /// Whether on-demand issuance is enabled.
  bool get isOnDemand => allowDomain != null;

  /// The renewal threshold as the underlying ACME client sees it — [renewBefore]
  /// is only a safety margin if it actually reaches `shelf_letsencrypt`.
  @visibleForTesting
  Duration get effectiveRenewBefore => _letsEncrypt.minCertificateValidityTime;

  /// Whether [host] may be served (a seed domain or allowed by the policy).
  ///
  /// [allowDomain] may be asynchronous, so this is too. It is consulted only
  /// from [obtain] — never from the synchronous SNI path ([contextFor]).
  Future<bool> isAllowed(String host) async {
    final normalized = host.toLowerCase();
    if (domains.any((d) => d.name.toLowerCase() == normalized)) return true;
    final policy = allowDomain;
    if (policy == null) return false;
    return await policy(normalized);
  }

  @override
  bool get supportsSni => isOnDemand || domains.length > 1;

  @override
  SecurityContext? get defaultContext => _default;

  @override
  SecurityContext? contextFor(String? host) {
    if (host == null) return _default;
    final normalized = host.toLowerCase();
    final cached = _contexts[normalized];
    if (cached != null) return cached;
    // Unknown host: provision in the background for next time. The allow-check
    // is async, so it cannot run here (SNI resolution must be synchronous) —
    // `obtain` performs it. `_denied` keeps a rejected host from re-invoking
    // the policy on every handshake. Swallow errors (e.g. a throwing email
    // resolver) so they never surface as an unhandled async error mid-handshake.
    if (!_inFlight.containsKey(normalized) && !_denied.contains(normalized)) {
      unawaited(obtain(normalized).catchError((Object _) => false));
    }
    return _default;
  }

  @override
  SecurityContext securityContext() {
    final context = _default;
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

  /// Ensures a certificate exists for [host] (provisioning it if allowed and
  /// missing) and caches its [SecurityContext]. Returns whether a certificate is
  /// available afterwards. Concurrent calls for the same host are de-duplicated.
  // Deliberately not `async`: `_inFlight` must be populated synchronously,
  // before the first suspension, or concurrent handshakes for the same host
  // would each start their own provisioning.
  Future<bool> obtain(String host) {
    final normalized = host.toLowerCase();
    if (_contexts.containsKey(normalized)) return Future.value(true);
    final existing = _inFlight[normalized];
    if (existing != null) return existing;
    final future = _obtain(normalized);
    _inFlight[normalized] = future;
    return future.whenComplete(() => _inFlight.remove(normalized));
  }

  Future<bool> _obtain(String host) async {
    if (!await isAllowed(host)) {
      if (_denied.length >= _maxDenied) _denied.clear();
      _denied.add(host);
      return false;
    }
    return _provisionHost(host);
  }

  @override
  Future<void> provision() async {
    for (final domain in domains) {
      final ok = await obtain(domain.name);
      if (!ok) {
        throw TlsException(
          'Failed to provision certificate for ${domain.name}',
        );
      }
    }
  }

  @override
  Future<bool> maybeRenew() async {
    // Certificates are provisioned out-of-band: never contact the CA.
    if (!autoIssue) return false;
    var refreshed = false;
    final hosts = <String>{
      ...domains.map((d) => d.name.toLowerCase()),
      ..._contexts.keys,
    };
    for (final host in hosts) {
      final status = await _letsEncrypt.checkCertificate(
        await _domainFor(host),
        requestCertificate: true,
      );
      if (status.isOkRefreshed) {
        final context = await _buildContextFor(host);
        if (context != null) {
          _contexts[host] = context;
          refreshed = true;
        }
      }
    }
    // SNI serves from the live cache, so an updated context is picked up on the
    // next handshake without rebinding; only the single-context path needs the
    // hub to rebind.
    return refreshed && !supportsSni;
  }

  Future<bool> _provisionHost(String host) async {
    final domain = await _domainFor(host);
    if (!_certificates.isHandledDomainCertificate(host)) {
      // No cached certificate: request one, unless issuance is disabled — then
      // this host is simply not served.
      if (!autoIssue) return false;
      final ok = await _letsEncrypt.requestCertificate(domain);
      if (!ok) return false;
    }
    final context = await _buildContextFor(host);
    if (context == null) return false;
    _contexts[host] = context;
    _default ??= context;
    return true;
  }

  Future<SecurityContext?> _buildContextFor(String host) async {
    final contexts = await _certificates.buildSecurityContexts(
      [await _domainFor(host)],
      allowUnresolvedDomain: true,
      loadAllHandledDomains: false,
    );
    if (contexts == null || contexts.isEmpty) return null;
    return contexts[host] ?? contexts.values.first;
  }

  Future<Domain> _domainFor(String host) async {
    for (final domain in domains) {
      if (domain.name.toLowerCase() == host) return domain;
    }
    return Domain(name: host, email: await _emailFor(host));
  }

  Future<String> _emailFor(String host) async {
    final resolver = onDemandEmailResolver;
    if (resolver != null) return resolver(host);
    final email = onDemandEmail;
    if (email != null) return email;
    // Only reachable for a seed host with no on-demand email; fall back to the
    // first seed domain's email.
    return domains.first.email;
  }

  shelf.Request _toShelf(HubRequest request) =>
      shelf.Request(request.method, request.uri, headers: request.headers);

  HubResponse _adapt(shelf.Response response) => HubResponse(
    statusCode: response.statusCode,
    headers: response.headers,
    body: response.read(),
  );
}
