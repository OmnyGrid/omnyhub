import '../core/transport_protocol.dart';
import 'route_context.dart';
import 'route_rule.dart';

/// Matches on the request path.
///
/// By default matches [prefix] as a segment-aligned prefix (`/api` matches
/// `/api` and `/api/x` but not `/apix`); with [exact], matches the path
/// exactly. A longer prefix reports higher [specificity], preserving
/// longest-prefix precedence.
class PathRule extends RouteRule {
  /// The normalised path prefix (or exact path).
  final String prefix;

  /// Whether the match must be exact rather than a prefix.
  final bool exact;

  /// Creates a path rule for [prefix].
  PathRule(String prefix, {this.exact = false}) : prefix = _normalize(prefix);

  @override
  bool matches(RouteContext context) {
    final path = context.path;
    if (prefix == '/') return exact ? path == '/' : true;
    if (exact) return path == prefix;
    return path == prefix || path.startsWith('$prefix/');
  }

  @override
  int get specificity => prefix.length + (exact ? 1 : 0);

  static String _normalize(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}

/// Matches the full host.
///
/// An exact host (`api.example.com`) or a wildcard suffix (`*.example.com`,
/// matching any subdomain depth).
class HostRule extends RouteRule {
  /// The host pattern, lower-cased.
  final String pattern;

  final bool _wildcard;

  /// Creates a host rule for [pattern].
  HostRule(String pattern)
    : pattern = pattern.toLowerCase(),
      _wildcard = pattern.startsWith('*.');

  @override
  bool matches(RouteContext context) {
    if (_wildcard) {
      final suffix = pattern.substring(1); // ".example.com"
      return context.host.endsWith(suffix);
    }
    return context.host == pattern;
  }

  @override
  int get specificity => 10 + pattern.length;
}

/// Which part of the host a [HostPatternRule] matches against.
enum HostPart {
  /// The full host (e.g. `api.example.com`).
  host,

  /// The registrable domain (e.g. `example.com`).
  domain,

  /// The subdomain (e.g. `api`).
  subdomain,
}

/// Matches a regular expression against the host (or its [part]).
///
/// Use this for host/domain routing beyond exact and `*.` wildcard matches —
/// e.g. `HostPatternRule(RegExp(r'^(dev|stg)\.example\.com$'))` or match a
/// subdomain shape with `part: HostPart.subdomain`. Combine with a [PathRule]
/// via `&` to route by host *and* path prefix.
class HostPatternRule extends RouteRule {
  /// The pattern matched against the selected host [part].
  final RegExp pattern;

  /// Which part of the host to match.
  final HostPart part;

  /// Creates a host-pattern rule.
  const HostPatternRule(this.pattern, {this.part = HostPart.host});

  @override
  bool matches(RouteContext context) => pattern.hasMatch(_value(context));

  String _value(RouteContext context) => switch (part) {
    HostPart.host => context.host,
    HostPart.domain => context.domain,
    HostPart.subdomain => context.subdomain,
  };

  @override
  int get specificity => 9;
}

/// Matches the registrable [domain] portion of the host (e.g. `example.com`).
class DomainRule extends RouteRule {
  /// The domain to match, lower-cased.
  final String domain;

  /// Creates a domain rule for [domain].
  DomainRule(String domain) : domain = domain.toLowerCase();

  @override
  bool matches(RouteContext context) => context.domain == domain;

  @override
  int get specificity => 5 + domain.length;
}

/// Matches the [subdomain] portion of the host (e.g. `api` for
/// `api.example.com`).
class SubdomainRule extends RouteRule {
  /// The subdomain to match, lower-cased.
  final String subdomain;

  /// Creates a subdomain rule for [subdomain].
  SubdomainRule(String subdomain) : subdomain = subdomain.toLowerCase();

  @override
  bool matches(RouteContext context) => context.subdomain == subdomain;

  @override
  int get specificity => 8 + subdomain.length;
}

/// Matches on a request header.
///
/// With [equals], the header must equal a value; with [contains], it must
/// contain a substring; otherwise the header must merely be present.
/// Comparisons are case-insensitive unless [caseSensitive] is set.
class HeaderRule extends RouteRule {
  /// The header name (compared case-insensitively).
  final String name;

  /// The exact value required, if any.
  final String? equals;

  /// The substring required, if any.
  final String? contains;

  /// Whether value comparison is case-sensitive.
  final bool caseSensitive;

  /// Creates a header rule. Provide [equals] or [contains] to constrain the
  /// value; provide neither to match on mere presence.
  const HeaderRule(
    this.name, {
    this.equals,
    this.contains,
    this.caseSensitive = false,
  });

  @override
  bool matches(RouteContext context) {
    final value = context.header(name);
    if (value == null) return false;
    final v = caseSensitive ? value : value.toLowerCase();
    if (equals != null) {
      return v == (caseSensitive ? equals : equals!.toLowerCase());
    }
    if (contains != null) {
      return v.contains(caseSensitive ? contains! : contains!.toLowerCase());
    }
    return true;
  }

  @override
  int get specificity => equals != null || contains != null ? 3 : 2;
}

/// Matches when the request protocol is one of [protocols].
class ProtocolRule extends RouteRule {
  /// The set of accepted protocols.
  final Set<TransportProtocol> protocols;

  /// Creates a protocol rule accepting [protocols].
  const ProtocolRule(this.protocols);

  /// Matches TLS protocols (`https`, `wss`).
  ProtocolRule.secure()
    : protocols = const {TransportProtocol.https, TransportProtocol.wss};

  /// Matches WebSocket protocols (`ws`, `wss`).
  ProtocolRule.webSocket()
    : protocols = const {TransportProtocol.ws, TransportProtocol.wss};

  @override
  bool matches(RouteContext context) => protocols.contains(context.protocol);

  @override
  int get specificity => 2;
}

/// Matches when the request method is one of [methods] (upper-cased).
class MethodRule extends RouteRule {
  /// The set of accepted methods, upper-cased.
  final Set<String> methods;

  /// Creates a method rule accepting [methods].
  MethodRule(Iterable<String> methods)
    : methods = methods.map((m) => m.toUpperCase()).toSet();

  @override
  bool matches(RouteContext context) => methods.contains(context.method);

  @override
  int get specificity => 2;
}

/// Matches on authentication state: whether the caller is authenticated, and
/// whether the principal holds required roles.
class AuthStateRule extends RouteRule {
  /// Required authentication state, or `null` if unconstrained.
  final bool? requireAuthenticated;

  /// The caller must hold at least one of these roles (if non-empty).
  final Set<String> anyRoles;

  /// The caller must hold all of these roles (if non-empty).
  final Set<String> allRoles;

  /// Creates an auth-state rule.
  const AuthStateRule({
    this.requireAuthenticated,
    this.anyRoles = const {},
    this.allRoles = const {},
  });

  /// Matches any authenticated caller.
  const AuthStateRule.authenticated() : this(requireAuthenticated: true);

  /// Matches only anonymous callers.
  const AuthStateRule.anonymous() : this(requireAuthenticated: false);

  /// Matches callers holding [role].
  AuthStateRule.hasRole(String role)
    : this(requireAuthenticated: true, allRoles: {role});

  /// Matches callers holding any of [roles].
  AuthStateRule.hasAnyRole(Set<String> roles)
    : this(requireAuthenticated: true, anyRoles: roles);

  @override
  bool matches(RouteContext context) {
    if (requireAuthenticated != null &&
        context.isAuthenticated != requireAuthenticated) {
      return false;
    }
    final principal = context.principal;
    if (anyRoles.isNotEmpty &&
        (principal == null || !principal.hasAnyRole(anyRoles))) {
      return false;
    }
    if (allRoles.isNotEmpty &&
        (principal == null || !principal.hasAllRoles(allRoles))) {
      return false;
    }
    return true;
  }

  @override
  int get specificity => 2 + anyRoles.length + allRoles.length;
}
