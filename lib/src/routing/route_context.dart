import '../core/principal.dart';
import '../core/transport_protocol.dart';
import '../http/hub_request.dart';

/// The immutable snapshot of a request that routing rules match against.
///
/// Built once per request from a [HubRequest] (after authentication, so
/// [principal] reflects auth state). Exposes the host split into [domain] and
/// [subdomain] using a simple two-label heuristic (see [RouteContext.fromRequest]).
class RouteContext {
  /// The HTTP method, upper-cased.
  final String method;

  /// The full requested URI.
  final Uri uri;

  /// The request path.
  final String path;

  /// The host (no port), lower-cased.
  final String host;

  /// The registrable domain portion of [host] (the last two labels, e.g.
  /// `example.com`), or the whole host if it has fewer than two labels or is an
  /// IP address.
  final String domain;

  /// The subdomain portion of [host] (everything before [domain], e.g. `api`
  /// for `api.example.com`), or an empty string if there is none.
  final String subdomain;

  /// The protocol the request arrived on.
  final TransportProtocol protocol;

  /// Request headers, with lower-cased keys.
  final Map<String, String> headers;

  /// The authenticated identity, or `null` if anonymous.
  final Principal? principal;

  /// The remote peer address, if known.
  final String? remoteAddress;

  /// Creates a route context. Prefer [RouteContext.fromRequest].
  RouteContext({
    required this.method,
    required this.uri,
    required this.path,
    required this.host,
    required this.domain,
    required this.subdomain,
    required this.protocol,
    required this.headers,
    this.principal,
    this.remoteAddress,
  });

  /// Builds a context from [request], splitting the host into [domain]/
  /// [subdomain].
  factory RouteContext.fromRequest(HubRequest request) {
    final host = request.host.toLowerCase();
    final (domain, subdomain) = _splitHost(host);
    return RouteContext(
      method: request.method,
      uri: request.uri,
      path: request.path,
      host: host,
      domain: domain,
      subdomain: subdomain,
      protocol: request.protocol,
      headers: request.headers,
      principal: request.principal,
      remoteAddress: request.remoteAddress,
    );
  }

  /// Whether a principal is attached (authenticated).
  bool get isAuthenticated => principal != null;

  /// The value of header [name] (case-insensitive), or `null`.
  String? header(String name) => headers[name.toLowerCase()];

  static (String domain, String subdomain) _splitHost(String host) {
    if (host.isEmpty || _isIpAddress(host)) return (host, '');
    final labels = host.split('.');
    if (labels.length <= 2) return (host, '');
    final domain = labels.sublist(labels.length - 2).join('.');
    final subdomain = labels.sublist(0, labels.length - 2).join('.');
    return (domain, subdomain);
  }

  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  static bool _isIpAddress(String host) =>
      host.contains(':') || _ipv4.hasMatch(host);
}
