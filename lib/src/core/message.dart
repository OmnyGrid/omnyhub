import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A single message exchanged over a [Connection].
///
/// Protocol-agnostic: a WebSocket carries [TextMessage]s as text frames and
/// [BinaryMessage]s as binary frames, but nothing in the message model assumes
/// WebSocket. The hierarchy is `sealed` so handlers can switch exhaustively.
@immutable
sealed class Message {
  const Message();

  /// Wraps a text payload.
  const factory Message.text(String data) = TextMessage;

  /// Wraps a binary payload.
  factory Message.binary(List<int> data) = BinaryMessage;
}

/// A UTF-8 text message.
@immutable
final class TextMessage extends Message {
  /// The text payload.
  final String data;

  /// Wraps [data] as a text message.
  const TextMessage(this.data);

  @override
  bool operator ==(Object other) => other is TextMessage && other.data == data;

  @override
  int get hashCode => data.hashCode;

  @override
  String toString() => 'TextMessage(${data.length} chars)';
}

/// A binary message.
@immutable
final class BinaryMessage extends Message {
  /// The binary payload.
  final Uint8List data;

  /// Wraps [data] as a binary message (copied into a [Uint8List]).
  BinaryMessage(List<int> data) : data = Uint8List.fromList(data);

  /// Decodes the payload as UTF-8 text.
  String get asString => utf8.decode(data);

  @override
  bool operator ==(Object other) {
    if (other is! BinaryMessage) return false;
    if (other.data.length != data.length) return false;
    for (var i = 0; i < data.length; i++) {
      if (other.data[i] != data[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(data);

  @override
  String toString() => 'BinaryMessage(${data.length} bytes)';
}
