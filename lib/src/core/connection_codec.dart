import 'connection.dart';
import 'message.dart';

/// Encodes values of type [T] to raw [Message]s and back — the seam between a
/// protocol's typed messages/frames and omnyhub's codec-free [Connection].
///
/// omnyhub's own node control protocol (`MessageCodec` for `NodeControlMessage`)
/// is a `ConnectionCodec`; an application with its own wire format (e.g. a
/// frame codec producing text control frames and binary data frames) implements
/// this and rides on omnyhub's transport via [TypedConnection] — no custom
/// connection type required.
abstract interface class ConnectionCodec<T> {
  /// Encodes [value] as a raw [Message] for the wire.
  Message encode(T value);

  /// Decodes an inbound [Message] into a [T]. Throw to reject a frame.
  T decode(Message message);
}

/// A typed view over a raw [Connection], applying a [ConnectionCodec] so callers
/// exchange decoded values ([T]) instead of raw [Message]s.
///
/// This is the shared "codec over a duplex connection" primitive: omnyhub's node
/// runtime uses `TypedConnection<NodeControlMessage>`, and an application layers
/// its own protocol by supplying a `ConnectionCodec<AppFrame>`. Undecodable
/// inbound messages are dropped (they never tear the connection down), matching
/// the fail-soft behaviour of frame-oriented protocols. Like [Connection],
/// [incoming] is single-subscription.
class TypedConnection<T> {
  /// The underlying raw connection.
  final Connection connection;

  /// The codec applied at the boundary.
  final ConnectionCodec<T> codec;

  /// Wraps [connection] with [codec].
  const TypedConnection(this.connection, this.codec);

  /// Inbound decoded values; undecodable messages are skipped.
  Stream<T> get incoming => connection.incoming.expand((message) {
    try {
      return [codec.decode(message)];
    } on Object {
      return const [];
    }
  });

  /// Whether the underlying connection is open.
  bool get isOpen => connection.isOpen;

  /// Completes when the underlying connection closes.
  Future<void> get done => connection.done;

  /// The remote peer address, if known.
  String? get remoteAddress => connection.remoteAddress;

  /// Encodes and sends [value].
  void send(T value) => connection.send(codec.encode(value));

  /// Closes the underlying connection.
  Future<void> close([int? code, String? reason]) =>
      connection.close(code, reason);
}
