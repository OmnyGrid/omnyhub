import 'dart:async';

import '../http/handler.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../shared/errors/hub_exception.dart';
import '../shared/utils/clock.dart';
import '../shared/utils/logger.dart';

/// Composes [middleware] around [handler], returning a single handler.
///
/// The first middleware in the list is outermost (runs first on the way in,
/// last on the way out).
HubRequestHandler composePipeline(
  HubRequestHandler handler,
  List<Middleware> middleware,
) {
  var composed = handler;
  for (final m in middleware.reversed) {
    composed = m(composed);
  }
  return composed;
}

/// Middleware that converts thrown [HubException]s into their typed error
/// responses and any other error into a generic `500`. Mounted outermost by the
/// hub so no handler failure escapes as an unformatted crash.
Middleware errorMapper({Logger logger = const NoopLogger()}) {
  return (HubRequestHandler inner) {
    return (HubRequest request) async {
      try {
        return await inner(request);
      } on HubException catch (e) {
        return HubResponse.error(e);
      } on Object catch (e, s) {
        logger.error(
          'Unhandled error handling request',
          context: {'path': request.path, 'error': '$e', 'stack': '$s'},
        );
        return HubResponse.error(
          const TransportException('Internal server error'),
        );
      }
    };
  };
}

/// Middleware that maps errors thrown by inner handlers to responses via [map]
/// — the seam for translating an application's own exception hierarchy into
/// [HubResponse]s.
///
/// [map] returns a [HubResponse] to use, or `null` to rethrow (letting the
/// hub's built-in [errorMapper] handle it — e.g. framework [HubException]s).
/// Place this in the hub's user-middleware layer (it runs inside [errorMapper]).
Middleware mapErrors(
  FutureOr<HubResponse?> Function(Object error, StackTrace stackTrace) map,
) {
  return (HubRequestHandler inner) {
    return (HubRequest request) async {
      try {
        return await inner(request);
      } on Object catch (e, s) {
        final mapped = await map(e, s);
        if (mapped != null) return mapped;
        rethrow;
      }
    };
  };
}

/// Builds a `{"success": true, "data": ...}` JSON response — a common envelope
/// for API services (e.g. omnydrive).
HubResponse successEnvelope(Object? data, {int statusCode = 200}) =>
    HubResponse.json({'success': true, 'data': data}, statusCode: statusCode);

/// Builds a `{"success": false, "error": {"code", "message"}}` JSON response.
HubResponse errorEnvelope(
  String code,
  String message, {
  int statusCode = 400,
}) => HubResponse.json({
  'success': false,
  'error': {'code': code, 'message': message},
}, statusCode: statusCode);

/// Middleware that logs one record per request with method, path, status and
/// elapsed milliseconds. Timing uses [clock] for testability.
Middleware logRequests({
  required Logger logger,
  Clock clock = const SystemClock(),
}) {
  return (HubRequestHandler inner) {
    return (HubRequest request) async {
      final start = clock.now();
      final response = await inner(request);
      final elapsed = clock.now().difference(start).inMilliseconds;
      logger.info(
        '${request.method} ${request.path} -> ${response.statusCode}',
        context: {
          'method': request.method,
          'path': request.path,
          'status': response.statusCode,
          'ms': elapsed,
        },
      );
      return response;
    };
  };
}
