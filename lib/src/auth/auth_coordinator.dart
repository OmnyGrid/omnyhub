import 'dart:async';

import 'package:meta/meta.dart';

import '../core/principal.dart';
import '../http/hub_request.dart';
import '../routing/route.dart';
import '../shared/errors/hub_exception.dart';
import 'authenticator.dart';

/// The outcome of the global [AuthCoordinator] for a request.
///
/// The coordinator decides *how* a request is authenticated: authenticate it
/// itself, let it through anonymously, delegate to the matched service's own
/// [Authenticator], or block it outright (a pre-check).
@immutable
sealed class AuthDecision {
  const AuthDecision();
}

/// The coordinator authenticated the caller as [principal].
@immutable
final class Authenticated extends AuthDecision {
  /// The authenticated identity.
  final Principal principal;

  /// Creates an authenticated decision.
  const Authenticated(this.principal);
}

/// Let the request proceed with no principal (bypass authentication).
@immutable
final class Anonymous extends AuthDecision {
  /// Creates an anonymous (bypass) decision.
  const Anonymous();
}

/// Use the matched service's own [Authenticator] (if any) to authenticate.
@immutable
final class Delegate extends AuthDecision {
  /// Creates a delegate decision.
  const Delegate();
}

/// Reject the request with [reason] — a pre-check block (e.g. rate limiting,
/// suspicious input) before any service is invoked.
@immutable
final class Blocked extends AuthDecision {
  /// Why the request was blocked (its [HubException.statusCode] is used).
  final HubException reason;

  /// Creates a blocked decision.
  const Blocked(this.reason);
}

/// The global authentication decision layer.
///
/// Runs after routing (so it sees the matched [Route]) and returns an
/// [AuthDecision]: authenticate globally, bypass, delegate to the service's own
/// authenticator, or block. This is where cross-cutting policy lives —
/// pre-checks, per-route auth selection, tenant gating. Per-service
/// authenticators are plain [Authenticator]s attached to routes.
abstract interface class AuthCoordinator {
  /// Decides how to authenticate [request] targeting [route].
  FutureOr<AuthDecision> authenticate(HubRequest request, Route route);
}

/// The default coordinator, giving backward-compatible behaviour:
///
/// * if the route has its own [Authenticator], [Delegate] to it;
/// * else if the request already has a principal (from the hub's global
///   pre-routing authenticator), report [Authenticated];
/// * else [Anonymous].
class DefaultAuthCoordinator implements AuthCoordinator {
  /// Creates the default coordinator.
  const DefaultAuthCoordinator();

  @override
  AuthDecision authenticate(HubRequest request, Route route) {
    if (route.authenticator != null) return const Delegate();
    final principal = request.principal;
    if (principal != null) return Authenticated(principal);
    return const Anonymous();
  }
}

/// An [AuthCoordinator] backed by a closure.
class CoordinatorFn implements AuthCoordinator {
  final FutureOr<AuthDecision> Function(HubRequest request, Route route) _fn;

  /// Creates a coordinator from [decide].
  const CoordinatorFn(
    FutureOr<AuthDecision> Function(HubRequest request, Route route) decide,
  ) : _fn = decide;

  @override
  FutureOr<AuthDecision> authenticate(HubRequest request, Route route) =>
      _fn(request, route);
}
