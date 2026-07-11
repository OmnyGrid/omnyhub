import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../http/handler.dart';
import '../../shared/errors/hub_exception.dart';
import 'tls_provider.dart';

/// A [TlsProvider] backed by certificate/key files that are **reloaded when
/// their contents change on disk** — for externally-managed certificates (a
/// cert-manager, certbot, a mounted secret) without restarting the hub.
///
/// [maybeRenew] re-reads both files and **byte-compares** them against the
/// loaded material; on any content change it rebuilds the [SecurityContext] and
/// returns `true`, so the hub's `renewTls()` gap-free rebind swaps the listener
/// to the new certificate. Byte comparison (not mtime) means a same-size
/// rotation is detected, and a partial write that fails to parse leaves the
/// previous certificate in place. There is no ACME/challenge involvement — use
/// [LetsEncryptTls] for that.
class ReloadableFileTls implements TlsProvider {
  /// The certificate chain file path.
  final String certificatePath;

  /// The private key file path.
  final String privateKeyPath;

  /// The private key password, if any.
  final String? password;

  SecurityContext _context;
  Uint8List _certBytes;
  Uint8List _keyBytes;

  ReloadableFileTls._(
    this.certificatePath,
    this.privateKeyPath,
    this.password,
    this._context,
    this._certBytes,
    this._keyBytes,
  );

  /// Loads from the certificate chain file [certificate] and key file
  /// [privateKey].
  factory ReloadableFileTls.files(
    String certificate,
    String privateKey, {
    String? password,
  }) {
    try {
      final certBytes = File(certificate).readAsBytesSync();
      final keyBytes = File(privateKey).readAsBytesSync();
      final context = _build(certBytes, keyBytes, password);
      return ReloadableFileTls._(
        certificate,
        privateKey,
        password,
        context,
        certBytes,
        keyBytes,
      );
    } on Object catch (e) {
      throw TlsException('Failed to load TLS certificate/key: $e');
    }
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
    final certBytes = _read(certificatePath);
    final keyBytes = _read(privateKeyPath);
    if (certBytes == null || keyBytes == null) return false; // missing/partial
    if (_bytesEqual(certBytes, _certBytes) &&
        _bytesEqual(keyBytes, _keyBytes)) {
      return false; // unchanged
    }
    final SecurityContext context;
    try {
      context = _build(certBytes, keyBytes, password);
    } on Object {
      return false; // mid-write / invalid: keep the previous certificate
    }
    _context = context;
    _certBytes = certBytes;
    _keyBytes = keyBytes;
    return true;
  }

  static SecurityContext _build(
    List<int> certBytes,
    List<int> keyBytes,
    String? password,
  ) => SecurityContext()
    ..useCertificateChainBytes(certBytes)
    ..usePrivateKeyBytes(keyBytes, password: password);

  static Uint8List? _read(String path) {
    try {
      return File(path).readAsBytesSync();
    } on Object {
      return null;
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
