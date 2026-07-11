import 'dart:async';

import '../core/connection.dart';
import '../http/handler.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import 'service.dart';

/// A [Service] backed by closures — the quickest way to host request/response
/// (and optionally WebSocket) logic without declaring a class.
///
/// ```dart
/// hub.registerService(HandlerService(
///   name: 'api',
///   mount: '/api',
///   handler: (req) async => HubResponse.json({'ok': true}),
/// ));
/// ```
///
/// ## WebSocket integration
///
/// A [HandlerService] serves ordinary requests through [handler] and — if an
/// [onConnection] handler is supplied — WebSocket connections on the **same**
/// mount/port.
///
/// When a client sends a WebSocket upgrade request whose route resolves to this
/// service, the hub performs the upgrade and invokes [onConnection] with the
/// established duplex [Connection] and the originating [HubRequest] (for host,
/// path, headers and the authenticated `principal`). The plain [handler] is
/// **not** called for upgrade requests; it only handles non-upgrade HTTP
/// requests to the same mount (e.g. a browser GET that should return a page or
/// an error hint).
///
/// ```dart
/// hub.registerService(HandlerService(
///   name: 'chat',
///   mount: '/chat',
///   // Non-upgrade GET /chat — a hint for plain HTTP clients.
///   handler: (req) async => HubResponse.text('Connect a WebSocket to /chat'),
///   // WebSocket GET /chat (Upgrade: websocket) — the live connection.
///   onConnection: (conn, req) {
///     conn.incoming.listen((msg) {
///       if (msg is TextMessage) conn.send(TextMessage('echo: ${msg.data}'));
///     });
///   },
/// ));
/// ```
///
/// If [onConnection] is `null` ([handlesWebSocket] is `false`), an upgrade
/// routed here is rejected: the hub closes the connection with the
/// `WsCloseCodes.unsupported` code (via [ServiceBase.handleConnection]).
class HandlerService extends ServiceBase {
  final HubRequestHandler _handler;
  final ConnectionHandler? _onConnection;
  final Future<void> Function()? _onStart;
  final Future<void> Function()? _onStop;

  /// Creates a service mounted at [mount] that dispatches requests to
  /// [handler] and, when provided, WebSocket upgrades to [onConnection].
  ///
  /// [handler] handles non-upgrade HTTP requests. [onConnection] handles
  /// WebSocket connections after the upgrade completes; omit it to reject
  /// upgrades (see the class docs and [handlesWebSocket]). [onStart]/[onStop]
  /// run on the corresponding lifecycle transitions.
  HandlerService({
    required super.name,
    super.mount,
    required HubRequestHandler handler,
    ConnectionHandler? onConnection,
    Future<void> Function()? onStart,
    Future<void> Function()? onStop,
  }) : _handler = handler,
       _onConnection = onConnection,
       _onStart = onStart,
       _onStop = onStop;

  /// Whether this service accepts WebSocket connections — i.e. an
  /// `onConnection` handler was supplied. When `false`, WebSocket upgrades
  /// routed to this service are rejected by [handleConnection].
  bool get handlesWebSocket => _onConnection != null;

  @override
  Future<HubResponse> handle(HubRequest request) => _handler(request);

  @override
  FutureOr<void> handleConnection(Connection connection, HubRequest request) {
    final onConnection = _onConnection;
    if (onConnection == null) {
      return super.handleConnection(connection, request);
    }
    return onConnection(connection, request);
  }

  @override
  Future<void> start() async => _onStart?.call();

  @override
  Future<void> stop() async => _onStop?.call();
}
