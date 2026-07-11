import '../core/principal.dart';
import '../http/hub_request.dart';
import '../shared/errors/hub_exception.dart';
import 'authenticator.dart';

/// Resolves a bearer token to a [Principal] (or `null` if the token is
/// unknown).
typedef TokenResolver = Future<Principal?> Function(String token);

/// Authenticates `Authorization: Bearer <token>` requests.
///
/// A missing `Authorization` header (or a non-Bearer scheme) yields anonymous
/// (`null`) so the token authenticator composes with others; a Bearer header
/// with an unknown token throws [UnauthorizedException].
class BearerTokenAuthenticator implements Authenticator {
  final TokenResolver _resolve;

  /// Authenticates against a fixed [tokens] map (`token → principal`).
  BearerTokenAuthenticator(Map<String, Principal> tokens)
    : _resolve = ((token) async => tokens[token]);

  /// Authenticates by delegating token validation to [resolver].
  BearerTokenAuthenticator.resolver(TokenResolver resolver)
    : _resolve = resolver;

  @override
  Future<Principal?> authenticate(HubRequest request) async {
    final header = request.header('authorization');
    if (header == null) return null;
    final parts = header.split(' ');
    if (parts.length != 2 || parts[0].toLowerCase() != 'bearer') return null;
    final principal = await _resolve(parts[1]);
    if (principal == null) {
      throw const UnauthorizedException('Invalid bearer token');
    }
    return principal;
  }
}
