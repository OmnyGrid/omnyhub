import 'route_context.dart';

/// A predicate over a [RouteContext] used to select a route.
///
/// Built-in rules cover host, domain, subdomain, path, protocol, method,
/// headers and authentication state; combine them with [and]/[or]/[not] (or the
/// `&`, `|`, `~` operators), and drop to [PredicateRule] for arbitrary logic.
/// The routing engine also uses [specificity] to break ties between rules of
/// equal route priority (a longer path prefix wins over a shorter one).
abstract class RouteRule {
  /// Creates a rule.
  const RouteRule();

  /// Whether this rule matches [context].
  bool matches(RouteContext context);

  /// A relative measure of how specific this rule is, used as a tie-breaker
  /// among matching routes of equal priority. Higher is more specific.
  int get specificity => 1;

  /// A rule matching when both this and [other] match.
  RouteRule and(RouteRule other) => AndRule([this, other]);

  /// A rule matching when either this or [other] matches.
  RouteRule or(RouteRule other) => OrRule([this, other]);

  /// A rule matching when this rule does not match.
  RouteRule not() => NotRule(this);

  /// Operator form of [and].
  RouteRule operator &(RouteRule other) => and(other);

  /// Operator form of [or].
  RouteRule operator |(RouteRule other) => or(other);

  /// Operator form of [not].
  RouteRule operator ~() => not();
}

/// Matches when every child rule matches. Specificity is the sum of children,
/// so a compound rule out-specifies its parts.
class AndRule extends RouteRule {
  /// The child rules, all of which must match.
  final List<RouteRule> rules;

  /// Creates an all-of rule over [rules].
  const AndRule(this.rules);

  @override
  bool matches(RouteContext context) => rules.every((r) => r.matches(context));

  @override
  int get specificity => rules.fold(0, (sum, r) => sum + r.specificity);
}

/// Matches when any child rule matches. Specificity is the maximum child.
class OrRule extends RouteRule {
  /// The child rules, any of which may match.
  final List<RouteRule> rules;

  /// Creates an any-of rule over [rules].
  const OrRule(this.rules);

  @override
  bool matches(RouteContext context) => rules.any((r) => r.matches(context));

  @override
  int get specificity =>
      rules.fold(0, (max, r) => r.specificity > max ? r.specificity : max);
}

/// Matches when the wrapped rule does not.
class NotRule extends RouteRule {
  /// The negated rule.
  final RouteRule rule;

  /// Creates a negation of [rule].
  const NotRule(this.rule);

  @override
  bool matches(RouteContext context) => !rule.matches(context);

  @override
  int get specificity => rule.specificity;
}

/// Matches when the supplied [predicate] returns true. The escape hatch for
/// arbitrary, user-defined routing logic.
class PredicateRule extends RouteRule {
  /// The user predicate.
  final bool Function(RouteContext context) predicate;

  /// The specificity to report (defaults to `1`).
  final int _specificity;

  /// Creates a predicate rule from [predicate], optionally overriding
  /// [specificity].
  const PredicateRule(this.predicate, {int specificity = 1})
    : _specificity = specificity;

  @override
  bool matches(RouteContext context) => predicate(context);

  @override
  int get specificity => _specificity;
}

/// A rule that always matches (the catch-all). Specificity `0`, so any real
/// rule wins the tie-break.
class AnyRule extends RouteRule {
  /// Creates a catch-all rule.
  const AnyRule();

  @override
  bool matches(RouteContext context) => true;

  @override
  int get specificity => 0;
}
