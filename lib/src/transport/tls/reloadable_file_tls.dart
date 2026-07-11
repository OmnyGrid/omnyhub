import 'dart:io';

import 'package:path/path.dart' as p;

import '../../http/handler.dart';
import '../../shared/errors/hub_exception.dart';
import 'tls_provider.dart';

/// A [TlsProvider] backed by certificate/key files that are **reloaded when
/// they change on disk** — for externally-managed certificates (a cert-manager,
/// certbot, a mounted secret) without restarting the hub.
///
/// [maybeRenew] rebuilds the [SecurityContext] when either file's
/// modification time or size changes and returns `true`, so the hub's
/// `renewTls()`/`HttpTransport.rebind()` swaps the listener to the new
/// certificate. There is no ACME/challenge involvement — use [LetsEncryptTls]
/// for that.
class ReloadableFileTls implements TlsProvider {
  /// The certificate chain file path.
  final String certificatePath;

  /// The private key file path.
  final String privateKeyPath;

  /// The private key password, if any.
  final String? password;

  SecurityContext _context;
  String _signature;

  ReloadableFileTls._(
    this.certificatePath,
    this.privateKeyPath,
    this.password,
    this._context,
    this._signature,
  );

  /// Loads from the certificate chain file [certificate] and key file
  /// [privateKey].
  factory ReloadableFileTls.files(
    String certificate,
    String privateKey, {
    String? password,
  }) {
    final context = _build(certificate, privateKey, password);
    final signature = _signatureOf(certificate, privateKey);
    return ReloadableFileTls._(
      certificate,
      privateKey,
      password,
      context,
      signature,
    );
  }

  /// Loads from a [directory] containing [certName]/[keyName] (defaults match
  /// the common `fullchain.pem`/`privkey.pem` layout).
  factory ReloadableFileTls.directory(
    String directory, {
    String certName = 'fullchain.pem',
    String keyName = 'privkey.pem',
    String? password,
  }) => ReloadableFileTls.files(
    p.join(directory, certName),
    p.join(directory, keyName),
    password: password,
  );

  @override
  SecurityContext securityContext() => _context;

  @override
  Middleware? get challengeMiddleware => null;

  @override
  bool get hotReloadable => true;

  @override
  Future<void> provision() async {}

  @override
  Future<bool> maybeRenew() async {
    final signature = _signatureOf(certificatePath, privateKeyPath);
    if (signature == _signature) return false;
    _context = _build(certificatePath, privateKeyPath, password);
    _signature = signature;
    return true;
  }

  static SecurityContext _build(String cert, String key, String? password) {
    try {
      return SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key, password: password);
    } on Object catch (e) {
      throw TlsException('Failed to load TLS certificate/key: $e');
    }
  }

  static String _signatureOf(String cert, String key) {
    String stat(String path) {
      try {
        final s = File(path).statSync();
        return '${s.modified.microsecondsSinceEpoch}:${s.size}';
      } on Object {
        return 'missing';
      }
    }

    return '${stat(cert)}|${stat(key)}';
  }
}
