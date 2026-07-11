import '../core/transport_protocol.dart';
import '../http/handler.dart';

/// A bound listener that accepts inbound traffic on one address/port and
/// normalises it into [HubRequest]s (and, on upgrade, [Connection]s).
///
/// This is the transport *port*: the hub depends only on this abstraction,
/// while concrete adapters (currently [HttpTransport], built on `shelf`) live
/// alongside it. A hub may run several transports at once (e.g. `:80` and
/// `:443`).
abstract interface class Transport {
  /// The base protocol served (`http` or `https`). Individual requests may be
  /// reported as `ws`/`wss` when they are WebSocket upgrades.
  TransportProtocol get protocol;

  /// The bound address (host or IP).
  Object get address;

  /// The port the listener is bound to. Valid only after [bind]; when bound
  /// with port `0` this reflects the ephemeral port actually chosen.
  int get port;

  /// Whether this transport terminates TLS.
  bool get isSecure;

  /// Whether the transport is currently bound and listening.
  bool get isBound;

  /// Binds and starts listening.
  ///
  /// [onRequest] handles ordinary requests; [onUpgrade], when provided, handles
  /// WebSocket upgrade requests (the transport performs the upgrade and hands
  /// over the [Connection]). Pass `port: 0` (in the constructor) to bind an
  /// ephemeral port and read [port] afterwards.
  Future<void> bind({
    required HubRequestHandler onRequest,
    ConnectionHandler? onUpgrade,
  });

  /// Stops the listener. With [force], open connections are dropped
  /// immediately.
  Future<void> close({bool force = false});
}
