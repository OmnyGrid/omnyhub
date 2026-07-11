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
class HandlerService extends ServiceBase {
  final HubRequestHandler _handler;
  final ConnectionHandler? _onConnection;
  final Future<void> Function()? _onStart;
  final Future<void> Function()? _onStop;

  /// Creates a service mounted at [mount] that dispatches requests to
  /// [handler], WebSocket upgrades to [onConnection] (if given), and runs
  /// [onStart]/[onStop] on lifecycle transitions.
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
