import 'package:shelf/shelf.dart' as shelf;

import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../service/service.dart';

/// A [Service] that adapts an existing `shelf` [shelf.Handler] — including a
/// `shelf_router.Router` with path parameters — so it can be hosted on a hub
/// unchanged.
///
/// Converts each [HubRequest] into a `shelf.Request` (streaming the body) and
/// the returned `shelf.Response` back into a [HubResponse] (streaming too).
/// Only depends on `shelf`; bring your own `shelf_router`.
///
/// ```dart
/// final router = shelf_router.Router()
///   ..get('/drives/<endpoint>/<name>', driveHandler);
/// hub.registerService(ShelfService(router.call, name: 'drive', mount: '/drives'));
/// ```
///
/// [handleConnection] is not supported (shelf handlers are request/response
/// only); WebSocket upgrades routed here are rejected by [ServiceBase].
class ShelfService extends ServiceBase {
  final shelf.Handler _handler;

  /// When true, the path handed to the shelf handler is made relative to
  /// [mount] (shelf's `handlerPath` convention); otherwise the full path is
  /// passed. Defaults to false, matching handlers with absolute route patterns.
  final bool stripMount;

  /// Wraps [handler]. [mount] is the path prefix the service is hosted at.
  ShelfService(
    shelf.Handler handler, {
    required super.name,
    super.mount,
    this.stripMount = false,
  }) : _handler = handler;

  @override
  Future<HubResponse> handle(HubRequest request) async {
    final normalizedMount = _normalizeMount(mount);
    String? handlerPath;
    if (stripMount && normalizedMount != '/') {
      handlerPath = '$normalizedMount/';
    }

    final shelfRequest = shelf.Request(
      request.method,
      request.uri,
      headers: request.headers,
      handlerPath: handlerPath,
      body: request.read(),
    );

    final shelfResponse = await _handler(shelfRequest);
    return HubResponse(
      statusCode: shelfResponse.statusCode,
      headers: shelfResponse.headers,
      body: shelfResponse.read(),
    );
  }

  static String _normalizeMount(String mount) {
    var m = mount.trim();
    if (m.isEmpty) return '/';
    if (!m.startsWith('/')) m = '/$m';
    while (m.length > 1 && m.endsWith('/')) {
      m = m.substring(0, m.length - 1);
    }
    return m;
  }
}
