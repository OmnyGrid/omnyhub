import 'error_codes.dart';

/// Base type for any expected, framework-level failure raised by OmnyHub.
///
/// The pipeline translates these into HTTP error responses via their
/// [statusCode]/[code]/[message]; node peers translate them into protocol error
/// messages. The hierarchy is `sealed` so callers can pattern-match
/// exhaustively — applications that need their own failure types raise
/// [AppException] rather than extending this directly.
sealed class HubException implements Exception {
  /// Stable, machine-readable error code (see [ErrorCodes]).
  final String code;

  /// Human-readable description of the failure.
  final String message;

  /// HTTP status code the pipeline should respond with.
  final int statusCode;

  const HubException({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  @override
  String toString() => '$runtimeType($code): $message';
}

/// Invalid input from a caller (malformed request, bad configuration value, a
/// value object that failed validation, ...).
class ValidationException extends HubException {
  /// Creates a validation failure with [message].
  const ValidationException(String message)
    : super(
        code: ErrorCodes.validationError,
        message: message,
        statusCode: 400,
      );
}

/// A request body could not be parsed as the expected JSON shape.
class InvalidJsonException extends HubException {
  /// Creates an invalid-JSON failure with [message].
  const InvalidJsonException(String message)
    : super(code: ErrorCodes.invalidJson, message: message, statusCode: 400);
}

/// A referenced resource (service, node, route target, ...) does not exist.
class NotFoundException extends HubException {
  /// Creates a not-found failure with [message] and an optional specific [code].
  const NotFoundException({
    super.code = ErrorCodes.notFound,
    required super.message,
  }) : super(statusCode: 404);
}

/// The caller is not authenticated (missing or invalid credentials).
class UnauthorizedException extends HubException {
  /// Creates an unauthorized failure; defaults to a generic [message].
  const UnauthorizedException([String message = 'Authentication required'])
    : super(code: ErrorCodes.unauthorized, message: message, statusCode: 401);
}

/// The caller is authenticated but not permitted to perform the operation.
class ForbiddenException extends HubException {
  /// Creates a forbidden failure; defaults to a generic [message].
  const ForbiddenException([String message = 'Access denied'])
    : super(code: ErrorCodes.forbidden, message: message, statusCode: 403);
}

/// The caller has sent too many requests, or a pre-check flagged the request as
/// abusive/suspicious (rate limiting, throttling).
class TooManyRequestsException extends HubException {
  /// Creates a too-many-requests failure; defaults to a generic [message].
  const TooManyRequestsException([String message = 'Too many requests'])
    : super(
        code: ErrorCodes.tooManyRequests,
        message: message,
        statusCode: 429,
      );
}

/// No route matched the request, or route resolution failed.
class RoutingException extends HubException {
  /// Creates a routing failure with [message] and an optional specific [code].
  const RoutingException({
    super.code = ErrorCodes.noRoute,
    required super.message,
  }) : super(statusCode: 404);
}

/// A reverse-proxy operation failed (upstream unreachable, upstream returned a
/// transport error, WebSocket upgrade to the upstream failed, ...).
class ProxyException extends HubException {
  /// Creates a proxy failure with [message] and an optional specific [code].
  const ProxyException({
    super.code = ErrorCodes.badGateway,
    required super.message,
  }) : super(statusCode: 502);
}

/// A transport-level failure (binding a listener, accepting a connection, ...).
class TransportException extends HubException {
  /// Creates a transport failure with [message].
  const TransportException(String message)
    : super(code: ErrorCodes.transportError, message: message, statusCode: 500);
}

/// A TLS or ACME (Let's Encrypt) failure (certificate load, provisioning,
/// renewal, ...).
class TlsException extends HubException {
  /// Creates a TLS failure with [message].
  const TlsException(String message)
    : super(code: ErrorCodes.tlsError, message: message, statusCode: 500);
}

/// A targeted node is not currently available (offline, or no node satisfies a
/// discovery query the request depended on).
class NodeUnavailableException extends HubException {
  /// Creates a node-unavailable failure with [message].
  const NodeUnavailableException(String message)
    : super(
        code: ErrorCodes.nodeUnavailable,
        message: message,
        statusCode: 503,
      );
}

/// A control-plane message could not be decoded or violated the protocol.
class ProtocolException extends HubException {
  /// Creates a protocol failure with [message].
  const ProtocolException(String message)
    : super(code: ErrorCodes.protocolError, message: message, statusCode: 400);
}

/// An operation exceeded its deadline.
///
/// Named to avoid colliding with `dart:async`'s `TimeoutException`.
class HubTimeoutException extends HubException {
  /// Creates a timeout failure with [message].
  const HubTimeoutException([String message = 'Operation timed out'])
    : super(code: ErrorCodes.timeout, message: message, statusCode: 504);
}

/// An application-defined failure, carrying its own [code] and [statusCode].
///
/// [HubException] is `sealed`, so an application cannot slot its own failure
/// types into the hierarchy — but everything that maps errors to the wire (the
/// pipeline's `errorMapper`, the hub's upgrade path, the node gateway's
/// registration handler) keys off [HubException], and anything else becomes an
/// opaque 500. This is the seam: translate the application's own exceptions into
/// an [AppException] and they render with the intended status and code.
///
/// ```dart
/// Middleware appErrors() => mapErrors((error, _) => switch (error) {
///   MyDomainException e => HubResponse.error(
///       AppException(code: e.code, message: e.message, statusCode: e.status)),
///   _ => null, // rethrow; let the framework's errorMapper handle it
/// });
/// ```
///
/// Prefer a built-in ([NotFoundException], [UnauthorizedException], ...) when
/// one fits — they carry the ecosystem's stable [ErrorCodes].
class AppException extends HubException {
  /// Creates an application failure with an explicit [code], [message] and
  /// [statusCode].
  const AppException({
    required super.code,
    required super.message,
    required super.statusCode,
  });
}
