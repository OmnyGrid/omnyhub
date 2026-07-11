import 'dart:convert';

import '../core/principal.dart';
import '../http/hub_request.dart';
import '../shared/errors/hub_exception.dart';
import 'authenticator.dart';

/// Resolves HTTP Basic credentials to a [Principal] (or `null` if invalid).
typedef BasicResolver =
    Future<Principal?> Function(String username, String password);

/// Authenticates `Authorization: Basic base64(user:pass)` requests.
///
/// A missing `Authorization` header (or a non-Basic scheme) yields anonymous
/// (`null`); a Basic header with wrong credentials throws
/// [UnauthorizedException].
class BasicAuthAuthenticator implements Authenticator {
  final BasicResolver _resolve;

  /// Authenticates against a fixed [credentials] map (`username → password`).
  /// The resulting principal is granted the roles from [roles] (if provided).
  BasicAuthAuthenticator(
    Map<String, String> credentials, {
    Set<String> Function(String username)? roles,
  }) : _resolve = ((username, password) async {
         if (credentials[username] != password) return null;
         return Principal(
           id: username,
           displayName: username,
           roles: roles?.call(username) ?? const {},
         );
       });

  /// Authenticates by delegating validation to [resolver].
  BasicAuthAuthenticator.resolver(BasicResolver resolver) : _resolve = resolver;

  @override
  Future<Principal?> authenticate(HubRequest request) async {
    final header = request.header('authorization');
    if (header == null) return null;
    final parts = header.split(' ');
    if (parts.length != 2 || parts[0].toLowerCase() != 'basic') return null;

    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(parts[1]));
    } on Object {
      throw const UnauthorizedException('Malformed basic credentials');
    }
    final sep = decoded.indexOf(':');
    if (sep < 0) {
      throw const UnauthorizedException('Malformed basic credentials');
    }

    final principal = await _resolve(
      decoded.substring(0, sep),
      decoded.substring(sep + 1),
    );
    if (principal == null) {
      throw const UnauthorizedException('Invalid credentials');
    }
    return principal;
  }
}
