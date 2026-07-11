import '../http/hub_request.dart';

/// Chooses the base URI a reverse proxy forwards a request to.
///
/// The returned URI provides the target scheme, host, port and optional base
/// path; [ProxyService] appends the (optionally rewritten) request path and
/// query. Implement this for custom target selection (sticky sessions,
/// weighted pools, per-tenant routing); the built-ins cover the common cases.
abstract interface class Upstream {
  /// Selects the base URI for [request].
  Uri select(HubRequest request);

  /// A fixed single upstream at [base] (e.g. `http://localhost:8080`).
  factory Upstream.uri(String base) => SingleUpstream(Uri.parse(base));

  /// A round-robin pool over [bases].
  factory Upstream.roundRobin(List<String> bases) =>
      RoundRobinUpstream(bases.map(Uri.parse).toList());
}

/// An [Upstream] that always returns the same [base] URI.
class SingleUpstream implements Upstream {
  /// The fixed base URI.
  final Uri base;

  /// Creates a single-target upstream.
  const SingleUpstream(this.base);

  @override
  Uri select(HubRequest request) => base;
}

/// An [Upstream] that cycles through [bases] on each selection.
class RoundRobinUpstream implements Upstream {
  /// The pool of base URIs.
  final List<Uri> bases;

  int _index = 0;

  /// Creates a round-robin upstream. [bases] must be non-empty.
  RoundRobinUpstream(this.bases)
    : assert(bases.isNotEmpty, 'bases must not be empty');

  @override
  Uri select(HubRequest request) {
    final base = bases[_index % bases.length];
    _index++;
    return base;
  }
}
