import 'dart:async';

import 'package:omnyhub/omnyhub.dart';

/// An in-memory [Connection] for unit-testing control-plane code without a real
/// socket.
///
/// [send] records messages in [sent] and (when paired) delivers them to the
/// peer's [incoming] stream. Use [LoopbackConnection.pair] to wire two ends
/// back-to-back; use [deliver] to simulate an inbound message in standalone
/// mode. Messages are passed by reference (no codec round-trip), which is
/// sufficient for routing/registry tests.
class LoopbackConnection implements Connection {
  final StreamController<Message> _incoming = StreamController<Message>();
  final List<Message> sent = [];
  final Completer<void> _done = Completer<void>();
  void Function(Message message)? _peerSink;
  Future<void> Function()? _onPeerClose;
  bool _open = true;

  @override
  final String? remoteAddress;

  /// Creates a standalone loopback connection.
  LoopbackConnection({this.remoteAddress = '127.0.0.1'});

  /// Creates two connections wired to each other.
  static (LoopbackConnection, LoopbackConnection) pair() {
    final a = LoopbackConnection();
    final b = LoopbackConnection();
    a._peerSink = b._incoming.add;
    b._peerSink = a._incoming.add;
    a._onPeerClose = b.close;
    b._onPeerClose = a.close;
    return (a, b);
  }

  @override
  Stream<Message> get incoming => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Message message) {
    if (!_open) return;
    sent.add(message);
    _peerSink?.call(message);
  }

  /// Simulates an inbound message arriving from the peer (standalone mode).
  void deliver(Message message) => _incoming.add(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    // Do not await: a single-subscription controller's close() future does not
    // complete until the stream has been listened to, which need not happen.
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
    final onPeerClose = _onPeerClose;
    _onPeerClose = null;
    if (onPeerClose != null) await onPeerClose();
  }
}
