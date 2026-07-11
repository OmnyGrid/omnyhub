import '../service/service.dart';
import 'route_context.dart';
import 'route_rule.dart';

/// Binds a [RouteRule] to a target [Service], with a [priority] for ordering.
class Route {
  /// A descriptive name (usually the target service's name).
  final String name;

  /// The rule that selects this route.
  final RouteRule rule;

  /// The service that handles requests matching [rule].
  final Service target;

  /// Higher priorities are preferred over lower ones when multiple routes
  /// match. Ties are broken by rule [RouteRule.specificity], then registration
  /// order.
  final int priority;

  /// Creates a route.
  Route({
    required this.name,
    required this.rule,
    required this.target,
    this.priority = 0,
  });

  @override
  String toString() => 'Route($name, priority: $priority)';
}

/// Selects at most one [Route] for a [RouteContext] from a routing table.
///
/// The default is [RuleRouter]; implement this interface to plug in a custom
/// routing strategy (weighted, longest-match-only, A/B, ...). The hub owns the
/// route list and passes it in, so custom routers still see service-mount
/// routes.
abstract interface class Router {
  /// Returns the best matching route in [routes] for [context], or `null` if
  /// none match.
  Route? resolve(RouteContext context, List<Route> routes);
}

/// The default [Router]: among matching routes, picks the highest
/// [Route.priority], breaking ties by rule [RouteRule.specificity] and then
/// registration order.
class RuleRouter implements Router {
  /// Creates the default rule router.
  const RuleRouter();

  @override
  Route? resolve(RouteContext context, List<Route> routes) {
    Route? best;
    for (final route in routes) {
      if (!route.rule.matches(context)) continue;
      if (best == null || _isBetter(route, best)) best = route;
    }
    return best;
  }

  bool _isBetter(Route candidate, Route current) {
    if (candidate.priority != current.priority) {
      return candidate.priority > current.priority;
    }
    return candidate.rule.specificity > current.rule.specificity;
  }
}
