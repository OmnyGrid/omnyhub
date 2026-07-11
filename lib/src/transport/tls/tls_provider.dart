import 'dart:io';

import '../../http/handler.dart';

/// Supplies TLS material to an HTTPS/WSS [Transport], and (for ACME providers)
/// the challenge middleware and provisioning/renewal hooks.
///
/// Static certificate files use [StaticTls]; automatic Let's Encrypt
/// provisioning uses `LetsEncryptTls`. Keeping this behind a port means the
/// transport never depends on the ACME implementation.
abstract interface class TlsProvider {
  /// The current [SecurityContext] to bind the listener with.
  ///
  /// Throws [TlsException] if certificates are not yet available (e.g. an ACME
  /// provider that has not completed [provision]).
  SecurityContext securityContext();

  /// A middleware that answers ACME HTTP-01 challenges, mounted first in the
  /// pipeline of the plaintext transport. `null` for providers that need no
  /// challenge handling (e.g. [StaticTls]).
  Middleware? get challengeMiddleware;

  /// Whether the [securityContext] may change at runtime (ACME renewal), in
  /// which case the hub rebinds the HTTPS transport after [maybeRenew] reports
  /// a refresh.
  bool get hotReloadable;

  /// Ensures certificates exist, provisioning them if necessary. A no-op for
  /// static providers.
  Future<void> provision();

  /// Renews certificates if they are near expiry. Returns `true` if the
  /// [securityContext] changed and the listener should be rebound. A no-op
  /// (returning `false`) for static providers.
  Future<bool> maybeRenew();
}

/// An optional capability a [TlsProvider] may also implement to serve multiple
/// certificates on one listener via **SNI** (Server Name Indication), selecting
/// (and, for dynamic providers, provisioning) a certificate per requested host.
///
/// When the TLS provider on an `HttpTransport` implements this and
/// [supportsSni] is true, the transport binds an SNI-aware listener whose
/// per-connection certificate is chosen by [contextFor]. Because the resolver
/// reads a live cache, a certificate obtained on demand is served on the very
/// next handshake — no rebind required. This is how a hub can serve
/// `foo.example.com`, `bar.example.com`, … without the domains being listed in
/// code up front.
///
/// > Clients must send an SNI hostname (every modern browser does). A client
/// > that connects without SNI — e.g. by raw IP address — is not served by the
/// > SNI listener; expose such access through a separate non-SNI HTTPS
/// > transport ([StaticTls]) if you need it.
abstract interface class SniTlsProvider {
  /// Whether the transport should use the SNI binding path for this provider.
  bool get supportsSni;

  /// The certificate context for [host] (the SNI hostname), or `null` if none
  /// is available yet. Called synchronously during the TLS handshake, so it
  /// must not block; dynamic providers may kick off background provisioning and
  /// return `null` (or a default) for now.
  SecurityContext? contextFor(String? host);

  /// The fallback context served when [contextFor] returns `null` (e.g. a
  /// client that sent no SNI). `null` means connections for unknown hosts are
  /// dropped until a certificate exists.
  SecurityContext? get defaultContext;
}
