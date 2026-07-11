import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/connection.dart';
import '../core/message.dart';

/// A [Connection] over a WebSocket (carried on TLS for `wss://`).
///
/// Wraps a [WebSocketChannel], translating raw text/binary frames to and from
/// [Message]s. Undecodable frames never tear the connection down. Used both
/// server-side (via [WebSocketConnection.fromChannel]) and client-side (via
/// [WebSocketConnection.connect], e.g. a node dialing a hub).
class WebSocketConnection implements Connection {
  final WebSocketChannel _channel;

  @override
  final String? remoteAddress;

  final StreamController<Message> _incoming = StreamController<Message>();
  final Completer<void> _done = Completer<void>();
  bool _open = true;

  WebSocketConnection._(this._channel, this.remoteAddress) {
    _channel.stream.listen(
      (event) {
        final message = switch (event) {
          String() => TextMessage(event),
          List<int>() => BinaryMessage(event),
          _ => null,
        };
        if (message != null) _incoming.add(message);
      },
      onDone: _handleClosed,
      onError: (Object _) => _handleClosed(),
      cancelOnError: false,
    );
  }

  /// Wraps an already-upgraded WebSocket [channel] (server side).
  factory WebSocketConnection.fromChannel(
    WebSocketChannel channel, {
    String? remoteAddress,
  }) => WebSocketConnection._(channel, remoteAddress);

  /// Dials [uri] (a `ws://`/`wss://` URL) and returns a connected connection.
  ///
  /// [headers] are sent on the upgrade request. [securityContext] supplies TLS
  /// trust roots; [onBadCertificate] is an escape hatch for self-signed test
  /// certificates. The connection is established before returning.
  static Future<WebSocketConnection> connect(
    Uri uri, {
    Map<String, dynamic>? headers,
    SecurityContext? securityContext,
    Duration? pingInterval,
    bool Function(X509Certificate cert, String host, int port)?
    onBadCertificate,
  }) async {
    final httpClient = HttpClient(context: securityContext);
    if (onBadCertificate != null) {
      httpClient.badCertificateCallback = onBadCertificate;
    }
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
      pingInterval: pingInterval,
      customClient: httpClient,
    );
    await channel.ready;
    return WebSocketConnection._(channel, uri.host);
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
    switch (message) {
      case TextMessage(:final data):
        _channel.sink.add(data);
      case BinaryMessage(:final data):
        _channel.sink.add(Uint8List.fromList(data));
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    await _channel.sink.close(code, reason);
    _handleClosed();
  }

  void _handleClosed() {
    _open = false;
    if (!_incoming.isClosed) _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}
