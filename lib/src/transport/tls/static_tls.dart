import 'dart:io';

import '../../http/handler.dart';
import '../../shared/errors/hub_exception.dart';
import 'tls_provider.dart';

/// A [TlsProvider] backed by a fixed certificate and key.
///
/// The certificate never changes at runtime ([hotReloadable] is `false`) and
/// there is no ACME challenge or renewal. Construct from PEM file paths with
/// [StaticTls.files], from PEM strings with [StaticTls.pem], or from an
/// already-built [SecurityContext] with [StaticTls.context].
class StaticTls implements TlsProvider {
  final SecurityContext _context;

  StaticTls._(this._context);

  /// Builds a context from an X.509 certificate chain file [certificateChain]
  /// and a private key file [privateKey] (optionally password-protected).
  factory StaticTls.files(
    String certificateChain,
    String privateKey, {
    String? password,
  }) {
    try {
      final context = SecurityContext()
        ..useCertificateChain(certificateChain)
        ..usePrivateKey(privateKey, password: password);
      return StaticTls._(context);
    } on Object catch (e) {
      throw TlsException('Failed to load TLS certificate/key: $e');
    }
  }

  /// Builds a context from PEM-encoded [certificateChain] and [privateKey]
  /// strings (optionally password-protected).
  factory StaticTls.pem(
    String certificateChain,
    String privateKey, {
    String? password,
  }) {
    try {
      final context = SecurityContext()
        ..useCertificateChainBytes(certificateChain.codeUnits)
        ..usePrivateKeyBytes(privateKey.codeUnits, password: password);
      return StaticTls._(context);
    } on Object catch (e) {
      throw TlsException('Failed to load TLS certificate/key: $e');
    }
  }

  /// Wraps an already-configured [SecurityContext].
  factory StaticTls.context(SecurityContext context) => StaticTls._(context);

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
