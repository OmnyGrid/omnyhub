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
/// [TypedConnection] to exchange decoded [NodeControlMessage]s directly. The
/// decoder set is extensible: third-party packages can [register] new message
/// types on top of [MessageCodec.standard], mirroring OmnyShell's `FrameCodec`
/// registry.
class MessageCodec implements ConnectionCodec<NodeControlMessage> {
  final Map<String, ControlDecoder> _decoders;

  /// Creates a codec with the given [decoders].
  MessageCodec(Map<String, ControlDecoder> decoders)
    : _decoders = Map.of(decoders);

  /// A codec pre-registered with all built-in control messages.
  factory MessageCodec.standard() => MessageCodec({
    NodeRegister.typeName: NodeRegister.fromJson,
    NodeRegistered.typeName: NodeRegistered.fromJson,
    Heartbeat.typeName: Heartbeat.fromJson,
    HeartbeatAck.typeName: HeartbeatAck.fromJson,
    NodeQuery.typeName: NodeQuery.fromJson,
    NodeQueryResult.typeName: NodeQueryResult.fromJson,
    NodeRequest.typeName: NodeRequest.fromJson,
    NodeResponse.typeName: NodeResponse.fromJson,
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
  /// Throws [ProtocolException] on malformed JSON or an unknown type.
  @override
  NodeControlMessage decode(Message message) {
    final text = switch (message) {
      TextMessage(:final data) => data,
      BinaryMessage() => message.asString,
    };
    final Object? raw;
    try {
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
