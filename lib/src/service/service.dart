import 'dart:async';

import '../core/connection.dart';
import '../core/ws_close.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';

/// A unit of business logic hosted by a hub, mounted at a path prefix.
///
/// Many services register into one hub and are exposed through the same
/// transport/port; the hub routes each request to the matching service. A
/// service handles ordinary requests via [handle] and, if it opts in, WebSocket
/// connections via [handleConnection].
///
/// Implement this directly, extend [ServiceBase] for sensible defaults, or use
/// [HandlerService] to wrap closures.
abstract interface class Service {
  /// A unique name within a hub (used for registration and removal).
  String get name;

  /// The path prefix this service is mounted at (e.g. `/api`). `/` mounts at
  /// the root. Normalised by the hub for matching.
  String get mount;

  /// Handles an ordinary request. The service receives the full [request]
  /// (its path is not stripped of [mount]).
  Future<HubResponse> handle(HubRequest request);

  /// Handles an upgraded WebSocket [connection] whose upgrade [request] matched
  /// this service. Services that do not serve WebSockets should close the
  /// connection.
  FutureOr<void> handleConnection(Connection connection, HubRequest request);

  /// Starts the service (open resources, connect to backends, ...). Called by
  /// the hub on [OmnyHub.start] or when registered into a running hub.
  Future<void> start();

  /// Stops the service and releases its resources.
  Future<void> stop();
}

/// A convenient base for services: no-op lifecycle and a WebSocket handler that
/// rejects the connection (code `1003`, "unsupported data"). Override [handle]
/// (required) and, to serve WebSockets, [handleConnection].
abstract class ServiceBase implements Service {
  @override
  final String name;

  @override
  final String mount;

  /// Creates a service named [name] mounted at [mount] (defaults to `/`).
  ServiceBase({required this.name, this.mount = '/'});

  @override
  FutureOr<void> handleConnection(Connection connection, HubRequest request) =>
      connection.close(WsCloseCodes.unsupported, 'WebSocket not supported');

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
