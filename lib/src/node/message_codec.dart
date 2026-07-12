import 'dart:convert';

import '../core/connection_codec.dart';
import '../core/message.dart';
import '../shared/errors/hub_exception.dart';
import '../shared/json/json.dart';
import 'node_control_message.dart';

/// Decodes a JSON body into a [NodeControlMessage].
typedef ControlDecoder = NodeControlMessage Function(Map<String, dynamic> json);

/// Encodes [NodeControlMessage]s to [Message]s and back, using a JSON envelope
/// `{"t": <type>, ...fields}`.
///
/// A [ConnectionCodec] over the node control protocol — pair it with a
/// [TypedConnection] to exchange decoded [NodeControlMessage]s directly.
///
/// [register] remaps a *wire type string* onto one of the built-in messages (to
/// accept a legacy or aliased discriminator). It cannot introduce a new message
/// type: [NodeControlMessage] is `sealed`, so its decoders can only ever return
/// a built-in. Application protocols ride on [NodeRequest]/[NodeResponse] and
/// [NodeNotify].
class MessageCodec implements ConnectionCodec<NodeControlMessage> {
  final Map<String, ControlDecoder> _decoders;

  /// Creates a codec with the given [decoders].
  MessageCodec(Map<String, ControlDecoder> decoders)
    : _decoders = Map.of(decoders);

  /// A codec pre-registered with all built-in control messages.
  factory MessageCodec.standard() => MessageCodec({
    NodeRegister.typeName: NodeRegister.fromJson,
    NodeRegistered.typeName: NodeRegistered.fromJson,
    NodeUpdate.typeName: NodeUpdate.fromJson,
    Heartbeat.typeName: Heartbeat.fromJson,
    HeartbeatAck.typeName: HeartbeatAck.fromJson,
    NodeQuery.typeName: NodeQuery.fromJson,
    NodeQueryResult.typeName: NodeQueryResult.fromJson,
    NodeRequest.typeName: NodeRequest.fromJson,
    NodeResponse.typeName: NodeResponse.fromJson,
    NodeNotify.typeName: NodeNotify.fromJson,
    NodeGoodbye.typeName: NodeGoodbye.fromJson,
    NodeErrorMessage.typeName: NodeErrorMessage.fromJson,
  });

  /// Registers a [decoder] for wire type [type], replacing any existing one.
  void register(String type, ControlDecoder decoder) {
    _decoders[type] = decoder;
  }

  /// Encodes [message] as a text [Message].
  @override
  Message encode(NodeControlMessage message) =>
      TextMessage(jsonEncode({'t': message.type, ...message.toJson()}));

  /// Decodes [message] into a [NodeControlMessage].
  ///
  /// Throws [ProtocolException] on a non-UTF-8 binary frame, malformed JSON, or
  /// an unknown type — never a raw `FormatException`, so callers can rely on
  /// catching [HubException] alone.
  @override
  NodeControlMessage decode(Message message) {
    final Object? raw;
    try {
      // A binary frame is only valid here if it happens to carry UTF-8 JSON;
      // `asString` throws on arbitrary bytes, so decode it inside the guard.
      final text = switch (message) {
        TextMessage(:final data) => data,
        BinaryMessage() => message.asString,
      };
      raw = jsonDecode(text);
    } on Object {
      throw const ProtocolException('Malformed control message JSON');
    }
    final json = Json.asObject(raw, 'control message');
    final type = Json.requireString(json, 't');
    final decoder = _decoders[type];
    if (decoder == null) {
      throw ProtocolException('Unknown control message type: $type');
    }
    return decoder(json);
  }
}
