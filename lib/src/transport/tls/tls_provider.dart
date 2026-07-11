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
