import 'package:shelf_letsencrypt/shelf_letsencrypt.dart' show Domain;

import '../hub/omny_hub.dart';
import '../proxy/proxy_service.dart';
import '../proxy/upstream.dart';
import '../routing/route_rule.dart';
import '../routing/rules.dart';
import '../shared/errors/hub_exception.dart';
import '../shared/json/json.dart';
import '../shared/utils/logger.dart';
import '../transport/http_transport.dart';
import '../transport/tls/lets_encrypt_tls.dart';
import '../transport/tls/static_tls.dart';
import '../transport/tls/tls_provider.dart';
import '../transport/transport.dart';

/// Builds a reverse-proxy / gateway [OmnyHub] from a declarative config map
/// (typically parsed from JSON by the `omnyhub` CLI).
///
/// Schema:
/// ```json
/// {
///   "listen": [
///     { "protocol": "http",  "address": "0.0.0.0", "port": 8080 },
///     { "protocol": "https", "port": 8443, "cert": "c.pem", "key": "k.pem" },
///     { "protocol": "https", "port": 443,
///       "letsencrypt": { "domains": [{"name":"x","email":"y"}],
///                        "cacheDir": "/var/omnyhub/certs", "production": false } }
///   ],
///   "routes": [
///     { "path": "/api", "target": "http://localhost:9000", "stripPrefix": "/api" },
///     { "host": "drive.example.com", "target": "http://localhost:9001", "priority": 10 }
///   ]
/// }
/// ```
Future<OmnyHub> buildGateway(
  Map<String, dynamic> config, {
  Logger logger = const NoopLogger(),
}) async {
  final transports = <Transport>[];
  for (final entry in _list(config, 'listen')) {
    transports.add(_buildTransport(Json.asObject(entry, 'listen entry')));
  }
  if (transports.isEmpty) {
    throw const ValidationException('config.listen must not be empty');
  }

  final hub = OmnyHub(transports: transports, logger: logger);

  var index = 0;
  for (final entry in _list(config, 'routes')) {
    final route = Json.asObject(entry, 'route');
    final target = Json.requireString(route, 'target');
    final name = Json.optString(route, 'name') ?? 'route-${index++}';
    final proxy = ProxyService(
      Upstream.uri(target),
      name: name,
      stripPrefix: Json.optString(route, 'stripPrefix'),
    );
    await hub.route(
      _buildRule(route),
      proxy,
      priority: Json.optInt(route, 'priority', 0)!,
    );
  }
  return hub;
}

Transport _buildTransport(Map<String, dynamic> entry) {
  final protocol = Json.optString(entry, 'protocol', 'http')!;
  final address = Json.optString(entry, 'address', '0.0.0.0')!;
  final port = Json.requireInt(entry, 'port');
  switch (protocol) {
    case 'http':
      return HttpTransport.http(address: address, port: port);
    case 'https':
      return HttpTransport.https(
        address: address,
        port: port,
        tls: _buildTls(entry),
      );
    default:
      throw ValidationException('Unknown protocol: $protocol');
  }
}

TlsProvider _buildTls(Map<String, dynamic> entry) {
  final letsEncrypt = entry['letsencrypt'];
  if (letsEncrypt is Map) {
    final le = letsEncrypt.cast<String, dynamic>();
    final domains = _list(le, 'domains')
        .map((d) => Json.asObject(d, 'domain'))
        .map(
          (d) => Domain(
            name: Json.requireString(d, 'name'),
            email: Json.requireString(d, 'email'),
          ),
        )
        .toList();
    return LetsEncryptTls(
      domains: domains,
      cacheDir: Json.requireString(le, 'cacheDir'),
      production: Json.optBool(le, 'production'),
    );
  }
  return StaticTls.files(
    Json.requireString(entry, 'cert'),
    Json.requireString(entry, 'key'),
  );
}

RouteRule _buildRule(Map<String, dynamic> route) {
  final path = Json.optString(route, 'path');
  final host = Json.optString(route, 'host');
  if (path != null && host != null) {
    return PathRule(path) & HostRule(host);
  }
  if (path != null) return PathRule(path);
  if (host != null) return HostRule(host);
  throw const ValidationException('route requires "path" and/or "host"');
}

List<Object?> _list(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return const [];
  if (value is List) return value;
  throw ValidationException('config.$key must be a list');
}
