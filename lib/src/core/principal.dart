import 'package:meta/meta.dart';

/// An authenticated identity attached to a request or a node connection.
///
/// Produced by an `Authenticator` and consumed by an `Authorizer`, by
/// auth-dependent routing rules, and by services. A `null` principal means the
/// caller is anonymous.
@immutable
class Principal {
  /// Stable identifier of the caller (user id, token subject, node id, ...).
  final String id;

  /// Human-friendly display name, if any.
  final String? displayName;

  /// Roles granted to this principal (e.g. `admin`, `service`).
  final Set<String> roles;

  /// Arbitrary additional claims/attributes.
  final Map<String, String> attributes;

  /// Creates a principal. [roles] and [attributes] are copied into unmodifiable
  /// collections.
  Principal({
    required this.id,
    this.displayName,
    Set<String> roles = const {},
    Map<String, String> attributes = const {},
  }) : roles = Set.unmodifiable(roles),
       attributes = Map.unmodifiable(attributes);

  /// Whether this principal has [role].
  bool hasRole(String role) => roles.contains(role);

  /// Whether this principal has every role in [required].
  bool hasAllRoles(Iterable<String> required) => required.every(hasRole);

  /// Whether this principal has any role in [candidates].
  bool hasAnyRole(Iterable<String> candidates) => candidates.any(hasRole);

  @override
  bool operator ==(Object other) =>
      other is Principal &&
      other.id == id &&
      other.displayName == displayName &&
      _setEquals(other.roles, roles) &&
      _mapEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    Object.hashAllUnordered(roles),
    Object.hashAllUnordered(
      attributes.entries.map((e) => '${e.key}=${e.value}'),
    ),
  );

  @override
  String toString() => 'Principal($id, roles: ${roles.join(',')})';

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
