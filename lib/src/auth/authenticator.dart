import '../core/principal.dart';
import '../http/hub_request.dart';
import '../shared/errors/hub_exception.dart';

/// Establishes the [Principal] behind a request.
///
/// Contract:
/// * no credentials present → return `null` (the caller is anonymous);
/// * credentials present but invalid → throw [UnauthorizedException]
///   (fail-closed);
/// * credentials present and valid → return the [Principal].
///
/// The hub runs the authenticator early in the pipeline and attaches the result
/// to `HubRequest.principal`, so auth-dependent routing and authorization see
/// it.
abstract interface class Authenticator {
  /// Authenticates [request]. See the class contract for the return/throw
  /// semantics.
  Future<Principal?> authenticate(HubRequest request);
}

/// An authenticator that treats every caller as anonymous (returns `null`).
/// The default — authentication is opt-in.
class AnonymousAuthenticator implements Authenticator {
  /// Creates an anonymous authenticator.
  const AnonymousAuthenticator();

  @override
  Future<Principal?> authenticate(HubRequest request) async => null;
}

/// Tries several authenticators in order, returning the first [Principal] one
/// produces.
///
/// If none authenticates the caller but at least one reported invalid
/// credentials (threw [UnauthorizedException]), that failure is propagated;
/// otherwise the caller is anonymous (`null`).
class CompositeAuthenticator implements Authenticator {
  /// The authenticators to try, in order.
  final List<Authenticator> authenticators;

  /// Creates a composite over [authenticators].
  const CompositeAuthenticator(this.authenticators);

  @override
  Future<Principal?> authenticate(HubRequest request) async {
    UnauthorizedException? pending;
    for (final authenticator in authenticators) {
      try {
        final principal = await authenticator.authenticate(request);
        if (principal != null) return principal;
      } on UnauthorizedException catch (e) {
        pending = e;
      }
    }
    if (pending != null) throw pending;
    return null;
  }
}
