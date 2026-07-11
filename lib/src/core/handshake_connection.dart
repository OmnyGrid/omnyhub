import 'dart:async';
import 'dart:collection';

import 'connection.dart';
import 'message.dart';

/// A [Connection] wrapper that lets an in-band authentication handshake pull the
/// first message(s) with [receive], then hands the (still-live) connection —
/// including any buffered-but-unread messages — to the service.
///
/// This solves the single-subscription problem: the underlying connection can
/// only be `listen`ed once, but both the auth hook and the service need to read
/// it. The wrapper owns the single subscription; [receive] serves the handshake
/// phase, and [incoming] (accessed by the service afterwards) replays whatever
/// the handshake did not consume and then streams live messages.
class HandshakeConnection implements Connection {
  final Connection _inner;
  final Queue<Message> _buffer = Queue<Message>();
  final Queue<Completer<Message>> _waiters = Queue<Completer<Message>>();
  late final StreamSubscription<Message> _sub;
  StreamController<Message>? _service;
  bool _released = false;

  /// Wraps [inner], immediately subscribing to it.
  HandshakeConnection(Connection inner) : _inner = inner {
    _sub = _inner.incoming.listen(
      _onMessage,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: false,
    );
  }

  /// Pulls the next inbound message for the handshake phase.
  ///
  /// Optionally fails after [timeout]. Must be called before the service starts
  /// reading [incoming].
  Future<Message> receive({Duration? timeout}) {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeFirst());
    final completer = Completer<Message>();
    _waiters.add(completer);
    final future = completer.future;
    return timeout == null ? future : future.timeout(timeout);
  }

  @override
  Stream<Message> get incoming {
    final service = _service ??= StreamController<Message>();
    if (!_released) {
      _released = true;
      while (_buffer.isNotEmpty) {
        service.add(_buffer.removeFirst());
      }
    }
    return service.stream;
  }

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Future<void> get done => _inner.done;

  @override
  String? get remoteAddress => _inner.remoteAddress;

  @override
  void send(Message message) => _inner.send(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    await _sub.cancel();
    if (!(_service?.isClosed ?? true)) await _service!.close();
    await _inner.close(code, reason);
  }

  void _onMessage(Message message) {
    if (_released) {
      _service?.add(message);
    } else if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(message);
    } else {
      _buffer.add(message);
    }
  }

  void _onDone() {
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Connection closed during handshake'));
      }
    }
    _waiters.clear();
    if (!(_service?.isClosed ?? true)) _service!.close();
  }

  void _onError(Object error) {
    _service?.addError(error);
  }
}
