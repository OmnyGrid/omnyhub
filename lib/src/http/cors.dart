import 'handler.dart';
import 'hub_response.dart';

/// Decides whether a browser [origin] (e.g. `https://app.example.com`) may call
/// this hub.
typedef OriginPredicate = bool Function(String origin);

/// The request headers a preflight is asked about, and the response headers it
/// is answered with, both vary by origin — so caches must be told.
const String _varyPreflight =
    'Origin, Access-Control-Request-Method, Access-Control-Request-Headers';

/// Cross-Origin Resource Sharing: lets a browser app served from another origin
/// call this hub.
///
/// Answers a preflight `OPTIONS` itself with a `204`, short-circuiting the
/// pipeline so it never reaches routing — otherwise it would come back as the
/// router's `405` or the hub's `404`, neither carrying CORS headers. Every other
/// response is passed through with `Access-Control-Allow-Origin` added.
///
/// Configure exactly one origin policy, or this throws [ArgumentError] —
/// silently allowing nothing is never what the caller meant:
///
/// * [allowedOrigins] — an exact allow-list. The matching origin is reflected
///   back (never the literal list).
/// * [allowOrigin] — a predicate, for wildcard subdomains or a tenant lookup.
/// * [allowAnyOrigin] — allow everything. Emits `*`, unless [allowCredentials]
///   is set, in which case the exact origin is reflected: the CORS specification
///   forbids `*` alongside credentials.
///
/// A request with no `Origin` header — every non-browser client — passes through
/// untouched, with no CORS headers added.
///
/// **Mount it in `outerMiddleware`**, not `use()`:
///
/// ```dart
/// final hub = OmnyHub(
///   transports: [HttpTransport.http(port: 8080)],
///   outerMiddleware: [cors(allowedOrigins: ['https://app.example.com'])],
/// );
/// ```
///
/// Ordinary middleware runs inside the hub's error mapping, so CORS mounted
/// there would never stamp a `401`, `404` or `500` — those become responses
/// above it — and a browser would see an opaque, unreadable error rather than
/// the real one. It would also never see a preflight, which arrives without
/// credentials and so is rejected by a strict authenticator first.
///
/// [allowedHeaders] permits `authorization` and `x-omny-principal` by default,
/// because that is what the omny APIs send; a preflight that does not list a
/// header the app then sends is rejected by the browser.
Middleware cors({
  Iterable<String> allowedOrigins = const [],
  OriginPredicate? allowOrigin,
  bool allowAnyOrigin = false,
  Iterable<String> allowedMethods = const [
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'OPTIONS',
  ],
  Iterable<String> allowedHeaders = const [
    'accept',
    'authorization',
    'content-type',
    'x-omny-principal',
    'x-requested-with',
  ],
  bool reflectRequestHeaders = false,
  Iterable<String> exposedHeaders = const [],
  bool allowCredentials = false,
  Duration maxAge = const Duration(hours: 24),
}) {
  final origins = allowedOrigins.map(_normalizeOrigin).toSet();
  if (origins.isEmpty && allowOrigin == null && !allowAnyOrigin) {
    throw ArgumentError(
      'cors() needs an origin policy: allowedOrigins, allowOrigin or '
      'allowAnyOrigin',
    );
  }

  // `*` is only legal — and only useful — when no specific origin was named and
  // no credentials ride along. Anything else reflects the caller's own origin.
  final wildcard =
      allowAnyOrigin &&
      !allowCredentials &&
      allowOrigin == null &&
      origins.isEmpty;

  bool allows(String origin) {
    if (allowOrigin != null) return allowOrigin(origin);
    if (origins.contains(_normalizeOrigin(origin))) return true;
    return allowAnyOrigin;
  }

  final methods = allowedMethods.join(', ');
  final headers = allowedHeaders.join(', ');
  final exposed = exposedHeaders.join(', ');

  return (inner) => (request) async {
    final origin = request.header('origin');
    // Not a browser. Leave the response exactly as it would be without CORS.
    if (origin == null || origin.isEmpty) return inner(request);

    final allowed = allows(origin);
    final acao = wildcard ? '*' : origin;

    // A preflight is an OPTIONS that names the method it is asking about. A bare
    // OPTIONS is a real request and still goes to the service.
    final isPreflight =
        request.method == 'OPTIONS' &&
        request.header('access-control-request-method') != null;

    if (isPreflight) {
      if (!allowed) {
        // No allow-origin: the browser rejects it. A 204 rather than a 403 so a
        // scan learns nothing about which routes exist.
        return HubResponse(statusCode: 204, headers: {'vary': _varyPreflight});
      }
      return HubResponse(
        statusCode: 204,
        headers: {
          'access-control-allow-origin': acao,
          'access-control-allow-methods': methods,
          'access-control-allow-headers': reflectRequestHeaders
              ? (request.header('access-control-request-headers') ?? headers)
              : headers,
          if (allowCredentials) 'access-control-allow-credentials': 'true',
          if (maxAge > Duration.zero)
            'access-control-max-age': '${maxAge.inSeconds}',
          'vary': _varyPreflight,
        },
      );
    }

    final response = await inner(request);
    if (!allowed) return response;

    return response.withHeaders({
      'access-control-allow-origin': acao,
      if (allowCredentials) 'access-control-allow-credentials': 'true',
      if (exposed.isNotEmpty) 'access-control-expose-headers': exposed,
      // A `*` response is the same for everyone, so there is nothing to vary on.
      if (!wildcard) 'vary': _mergeVary(response.headers['vary']),
    });
  };
}

/// Appends `Origin` to whatever the handler already varies on, rather than
/// clobbering it (a proxied response may well carry `vary: accept-encoding`).
String _mergeVary(String? existing) {
  if (existing == null || existing.trim().isEmpty) return 'Origin';
  final parts = existing.split(',').map((p) => p.trim());
  if (parts.any((p) => p.toLowerCase() == 'origin')) return existing;
  return '$existing, Origin';
}

/// Origins compare case-insensitively, and a trailing slash is not part of one.
String _normalizeOrigin(String origin) {
  var o = origin.trim().toLowerCase();
  while (o.endsWith('/')) {
    o = o.substring(0, o.length - 1);
  }
  return o;
}
