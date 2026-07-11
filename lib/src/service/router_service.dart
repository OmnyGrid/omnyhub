import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../routing/path_pattern.dart';
import 'service.dart';

/// Handles a request whose path matched a [PathPattern], with the captured
/// [params].
typedef ParamRequestHandler =
    Future<HubResponse> Function(
      HubRequest request,
      Map<String, String> params,
    );

/// A [Service] that dispatches to sub-routes by HTTP method and a
/// [PathPattern], exposing captured path parameters — the intra-service
/// equivalent of `shelf_router`, without leaving the `HubRequest`/`HubResponse`
/// model.
///
/// ```dart
/// final api = RouterService(name: 'drive', mount: '/drives')
///   ..get('/drives/<endpoint>/<name>', (req, p) async =>
///       HubResponse.json({'drive': '${p['endpoint']}/${p['name']}'}))
///   ..get('/drives/<endpoint>/<name>/files/<path|.*>', (req, p) async =>
///       serveFile(p['endpoint']!, p['name']!, p['path']!));
/// hub.registerService(api);
/// ```
///
/// A path that matches a pattern but not its method yields `405`; no match at
/// all yields `404`. Captured params are also stored in
/// `request.context['params']`.
class RouterService extends ServiceBase {
  final List<_Entry> _entries = [];

  /// Creates a router service mounted at [mount].
  RouterService({required super.name, super.mount});

  /// Registers a handler for [method] (upper-cased) on [pattern].
  RouterService on(String method, String pattern, ParamRequestHandler handler) {
    _entries.add(_Entry(method.toUpperCase(), PathPattern(pattern), handler));
    return this;
  }

  /// Registers a `GET` handler.
  RouterService get(String pattern, ParamRequestHandler handler) =>
      on('GET', pattern, handler);

  /// Registers a `POST` handler.
  RouterService post(String pattern, ParamRequestHandler handler) =>
      on('POST', pattern, handler);

  /// Registers a `PUT` handler.
  RouterService put(String pattern, ParamRequestHandler handler) =>
      on('PUT', pattern, handler);

  /// Registers a `DELETE` handler.
  RouterService delete(String pattern, ParamRequestHandler handler) =>
      on('DELETE', pattern, handler);

  /// Registers a handler for any method on [pattern].
  RouterService all(String pattern, ParamRequestHandler handler) =>
      on('*', pattern, handler);

  @override
  Future<HubResponse> handle(HubRequest request) async {
    var pathMatched = false;
    for (final entry in _entries) {
      final params = entry.pattern.match(request.path);
      if (params == null) continue;
      pathMatched = true;
      if (entry.method == '*' || entry.method == request.method) {
        request.context['params'] = params;
        return entry.handler(request, params);
      }
    }
    // A path matched but no method did => 405; otherwise 404.
    return HubResponse.text(
      pathMatched ? 'Method Not Allowed' : 'Not Found',
      statusCode: pathMatched ? 405 : 404,
    );
  }
}

class _Entry {
  final String method;
  final PathPattern pattern;
  final ParamRequestHandler handler;
  _Entry(this.method, this.pattern, this.handler);
}
