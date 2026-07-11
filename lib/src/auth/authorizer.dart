import '../core/principal.dart';
import '../routing/route_context.dart';

/// Decides whether an (already authenticated) caller may proceed with a
/// request — a coarse, hub-wide policy gate.
///
/// Fine-grained, per-route access control is better expressed with an
/// `AuthStateRule` on the route itself; the [Authorizer] is the global backstop.
/// It runs after routing, so [context] reflects the matched request. Fail
/// closed: the built-ins deny by default when a requirement is unmet.
abstract interface class Authorizer {
  /// Whether [principal] (possibly `null` for anonymous) may proceed with the
  /// request described by [context].
  Future<bool> authorize(Principal? principal, RouteContext context);
}

/// Allows every request. The default — authorization is opt-in.
class AllowAllAuthorizer implements Authorizer {
  /// Creates an allow-all authorizer.
  const AllowAllAuthorizer();

  @override
  Future<bool> authorize(Principal? principal, RouteContext context) async =>
      true;
}

/// Denies every request.
class DenyAllAuthorizer implements Authorizer {
  /// Creates a deny-all authorizer.
  const DenyAllAuthorizer();

  @override
  Future<bool> authorize(Principal? principal, RouteContext context) async =>
      false;
}

/// Requires authentication and (optionally) that the caller hold one of a set
/// of roles.
class RoleBasedAuthorizer implements Authorizer {
  /// If non-empty, the caller must hold at least one of these roles.
  final Set<String> anyRoles;

  /// Whether an authenticated principal is required.
  final bool requireAuthenticated;

  /// Creates a role-based authorizer.
  const RoleBasedAuthorizer({
    this.anyRoles = const {},
    this.requireAuthenticated = true,
  });

  @override
  Future<bool> authorize(Principal? principal, RouteContext context) async {
    if (requireAuthenticated && principal == null) return false;
    if (anyRoles.isEmpty) return true;
    return principal != null && principal.hasAnyRole(anyRoles);
  }
}

/// An authorizer backed by a predicate.
class PredicateAuthorizer implements Authorizer {
  final Future<bool> Function(Principal? principal, RouteContext context)
  _predicate;

  /// Creates an authorizer from [predicate].
  const PredicateAuthorizer(this._predicate);

  @override
  Future<bool> authorize(Principal? principal, RouteContext context) =>
      _predicate(principal, context);
}
