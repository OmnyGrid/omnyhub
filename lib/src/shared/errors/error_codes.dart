/// Stable, machine-readable error codes returned to API consumers and used
/// internally to classify failures. Always snake_case; treated as a wire
/// contract, so existing values must not change.
class ErrorCodes {
  // Generic.
  static const String validationError = 'validation_error';
  static const String invalidJson = 'invalid_json';
  static const String notFound = 'not_found';
  static const String internalError = 'internal_error';
  static const String timeout = 'timeout';

  // Auth & access control.
  static const String unauthorized = 'unauthorized';
  static const String forbidden = 'forbidden';

  // Routing & service hosting.
  static const String noRoute = 'no_route';
  static const String serviceNotFound = 'service_not_found';
  static const String serviceAlreadyExists = 'service_already_exists';

  // Reverse proxy.
  static const String proxyError = 'proxy_error';
  static const String badGateway = 'bad_gateway';

  // Transport & TLS.
  static const String transportError = 'transport_error';
  static const String tlsError = 'tls_error';

  // Nodes.
  static const String nodeUnavailable = 'node_unavailable';
  static const String nodeNotFound = 'node_not_found';
  static const String protocolError = 'protocol_error';

  const ErrorCodes._();
}
