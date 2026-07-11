import 'message.dart';

/// A duplex, message-oriented link between two peers.
///
/// This is the transport *port* for the control/node plane: the node protocol
/// and runtimes depend only on this abstraction, while the concrete WebSocket
/// adapter lives in `src/transport/`. Every value is an already-framed
/// [Message]; framing and codec concerns are the adapter's responsibility.
///
/// Use `LoopbackConnection.pair()` (in `test/support/`) to wire two ends
/// back-to-back for tests without a socket.
abstract interface class Connection {
  /// Inbound messages from the peer. A single-subscription stream; it closes
  /// when the connection closes.
  Stream<Message> get incoming;

  /// Whether the connection is currently open.
  bool get isOpen;

  /// Completes when the connection has fully closed.
  Future<void> get done;

  /// The remote address of the peer, if known (e.g. `203.0.113.4`).
  String? get remoteAddress;

  /// Sends [message] to the peer. Silently dropped if the connection is closed.
  void send(Message message);

  /// Closes the connection, optionally with a WebSocket [code]/[reason].
  Future<void> close([int? code, String? reason]);
}
