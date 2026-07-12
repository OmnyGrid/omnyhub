import 'package:meta/meta.dart';

import '../shared/json/json.dart';
import 'node_descriptor.dart';

/// A control-plane message exchanged between a node and a hub over the WebSocket
/// control connection.
///
/// The hierarchy is `sealed` so `NodeGateway` and `NodeRuntime` can switch
/// exhaustively. Each concrete type declares a wire [type] name and hand-written
/// [toJson]/`fromJson` (no code generation), matching the ecosystem convention.
///
/// Being `sealed`, this hierarchy is **closed to other libraries**: an
/// application cannot add its own message types, and `MessageCodec.register`
/// only remaps a wire string onto one of the built-ins. Carry an application
/// protocol over the control channel with [NodeRequest]/[NodeResponse] (call and
/// response) or [NodeNotify] (one-way push), whose `action` + `payload` are
/// yours to define.
@immutable
sealed class NodeControlMessage {
  const NodeControlMessage();

  /// The wire type discriminator (the `t` envelope field).
  String get type;

  /// The message body (without the `t` discriminator).
  Map<String, dynamic> toJson();
}

/// Node → hub: announce presence and advertised capabilities.
@immutable
final class NodeRegister extends NodeControlMessage {
  static const typeName = 'register';

  /// The full descriptor the node advertises.
  final NodeDescriptor descriptor;

  /// Application data submitted with the registration (e.g. a certificate
  /// signing request, an enrolment secret).
  ///
  /// Interpreted by the hub's registration handler; the hub's own bookkeeping
  /// ignores it.
  final Map<String, dynamic> payload;

  /// Registers [descriptor], optionally with an application [payload].
  const NodeRegister(this.descriptor, {this.payload = const {}});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'descriptor': descriptor.toJson(),
    if (payload.isNotEmpty) 'payload': payload,
  };

  /// Decodes from [json].
  static NodeRegister fromJson(Map<String, dynamic> json) => NodeRegister(
    NodeDescriptor.fromJson(Json.asObject(json['descriptor'])),
    payload: Json.optObject(json, 'payload'),
  );
}

/// Hub → node: acknowledge registration, advertising the expected heartbeat
/// interval.
@immutable
final class NodeRegistered extends NodeControlMessage {
  static const typeName = 'registered';

  /// The hub's identifier.
  final String hubId;

  /// The heartbeat interval (ms) the node should use.
  final int heartbeatIntervalMs;

  /// Application data returned by the hub's registration handler (e.g. a signed
  /// certificate, an assigned lease).
  final Map<String, dynamic> payload;

  /// Acknowledges registration, optionally with an application [payload].
  const NodeRegistered(
    this.hubId,
    this.heartbeatIntervalMs, {
    this.payload = const {},
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'hubId': hubId,
    'heartbeatIntervalMs': heartbeatIntervalMs,
    if (payload.isNotEmpty) 'payload': payload,
  };

  /// Decodes from [json].
  static NodeRegistered fromJson(Map<String, dynamic> json) => NodeRegistered(
    Json.requireString(json, 'hubId'),
    Json.requireInt(json, 'heartbeatIntervalMs'),
    payload: Json.optObject(json, 'payload'),
  );
}

/// Node → hub: revise the advertised descriptor without re-registering.
///
/// Fire-and-forget: the hub replaces the descriptor in its registry (keeping the
/// node's connection and liveness) and does not ack.
@immutable
final class NodeUpdate extends NodeControlMessage {
  static const typeName = 'update';

  /// The descriptor that replaces the currently advertised one.
  final NodeDescriptor descriptor;

  /// Advertises [descriptor] in place of the previous one.
  const NodeUpdate(this.descriptor);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'descriptor': descriptor.toJson()};

  /// Decodes from [json].
  static NodeUpdate fromJson(Map<String, dynamic> json) =>
      NodeUpdate(NodeDescriptor.fromJson(Json.asObject(json['descriptor'])));
}

/// Node → hub: liveness ping carrying a monotonic sequence number.
@immutable
final class Heartbeat extends NodeControlMessage {
  static const typeName = 'heartbeat';

  /// The monotonic sequence number.
  final int seq;

  /// Application data piggy-backed on the beat (e.g. a resource-metrics
  /// snapshot), produced by [NodeConfig.heartbeatPayload] and consumed by the
  /// gateway's `onHeartbeat` hook.
  ///
  /// The hub's own liveness bookkeeping ignores it. Riding the heartbeat avoids
  /// a second periodic message for telemetry a node already reports on the same
  /// cadence; keep it small, since it is sent on every beat.
  final Map<String, dynamic> payload;

  /// Creates a heartbeat with sequence [seq].
  const Heartbeat(this.seq, {this.payload = const {}});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'seq': seq,
    if (payload.isNotEmpty) 'payload': payload,
  };

  /// Decodes from [json].
  static Heartbeat fromJson(Map<String, dynamic> json) => Heartbeat(
    Json.requireInt(json, 'seq'),
    payload: Json.optObject(json, 'payload'),
  );
}

/// Hub → node: acknowledge a [Heartbeat].
@immutable
final class HeartbeatAck extends NodeControlMessage {
  static const typeName = 'heartbeat_ack';

  /// The acknowledged sequence number.
  final int seq;

  /// Acknowledges heartbeat [seq].
  const HeartbeatAck(this.seq);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'seq': seq};

  /// Decodes from [json].
  static HeartbeatAck fromJson(Map<String, dynamic> json) =>
      HeartbeatAck(Json.requireInt(json, 'seq'));
}

/// Node → hub: discover peer nodes matching a capability/label filter.
@immutable
final class NodeQuery extends NodeControlMessage {
  static const typeName = 'query';

  /// Correlation id echoed in the [NodeQueryResult].
  final String requestId;

  /// Required capability, if any.
  final String? capability;

  /// Required labels (all must match).
  final Map<String, String> labels;

  /// An application-defined filter, interpreted hub-side by a `NodeMatcher`.
  ///
  /// [capability] and [labels] cover the built-in flat matching; use [filter]
  /// for query semantics the hub cannot know about (version ranges, nested
  /// catalogues). Ignored unless the gateway has a matcher configured.
  final Map<String, dynamic> filter;

  /// Creates a discovery query.
  const NodeQuery(
    this.requestId, {
    this.capability,
    this.labels = const {},
    this.filter = const {},
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    if (capability != null) 'capability': capability,
    'labels': labels,
    if (filter.isNotEmpty) 'filter': filter,
  };

  /// Decodes from [json].
  static NodeQuery fromJson(Map<String, dynamic> json) => NodeQuery(
    Json.requireString(json, 'requestId'),
    capability: Json.optString(json, 'capability'),
    labels: Json.optStringMap(json, 'labels'),
    filter: Json.optObject(json, 'filter'),
  );
}

/// Hub → node: the result of a [NodeQuery].
@immutable
final class NodeQueryResult extends NodeControlMessage {
  static const typeName = 'query_result';

  /// The correlation id from the originating [NodeQuery].
  final String requestId;

  /// The matching node descriptors.
  final List<NodeDescriptor> nodes;

  /// Creates a query result.
  const NodeQueryResult(this.requestId, this.nodes);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };

  /// Decodes from [json].
  static NodeQueryResult fromJson(Map<String, dynamic> json) {
    final raw = (json['nodes'] as List? ?? const [])
        .map((e) => NodeDescriptor.fromJson(Json.asObject(e)))
        .toList();
    return NodeQueryResult(Json.requireString(json, 'requestId'), raw);
  }
}

/// Hub → node: invoke an application-defined [action] on the node (a simple
/// request/response RPC over the control channel).
@immutable
final class NodeRequest extends NodeControlMessage {
  static const typeName = 'request';

  /// Correlation id echoed in the [NodeResponse].
  final String requestId;

  /// The application-defined action name.
  final String action;

  /// The request payload.
  final Map<String, dynamic> payload;

  /// Creates a node request.
  const NodeRequest(this.requestId, this.action, {this.payload = const {}});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'action': action,
    'payload': payload,
  };

  /// Decodes from [json].
  static NodeRequest fromJson(Map<String, dynamic> json) => NodeRequest(
    Json.requireString(json, 'requestId'),
    Json.requireString(json, 'action'),
    payload: json['payload'] is Map ? Json.asObject(json['payload']) : const {},
  );
}

/// Node → hub: the result of a [NodeRequest].
@immutable
final class NodeResponse extends NodeControlMessage {
  static const typeName = 'response';

  /// The correlation id from the originating [NodeRequest].
  final String requestId;

  /// Whether the action succeeded.
  final bool ok;

  /// The response payload (on success).
  final Map<String, dynamic> payload;

  /// The error message (on failure).
  final String? error;

  /// Creates a node response.
  const NodeResponse(
    this.requestId, {
    this.ok = true,
    this.payload = const {},
    this.error,
  });

  /// A failed response with [error].
  factory NodeResponse.failure(String requestId, String error) =>
      NodeResponse(requestId, ok: false, error: error);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    'payload': payload,
    if (error != null) 'error': error,
  };

  /// Decodes from [json].
  static NodeResponse fromJson(Map<String, dynamic> json) => NodeResponse(
    Json.requireString(json, 'requestId'),
    ok: Json.optBool(json, 'ok', fallback: true),
    payload: json['payload'] is Map ? Json.asObject(json['payload']) : const {},
    error: Json.optString(json, 'error'),
  );
}

/// Either direction: a one-way, fire-and-forget application message.
///
/// The counterpart of [NodeRequest]: same `action` + `payload` shape, but no
/// correlation id and no reply. Use it for unsolicited pushes where a response
/// would be pure overhead — a node streaming log batches or status snapshots up
/// to the hub, a hub broadcasting a configuration change down to a node.
///
/// A dropped notify is not retried and not reported. Anything that needs an
/// answer, an acknowledgement, or delivery confirmation belongs in
/// [NodeRequest]/[NodeResponse] instead.
@immutable
final class NodeNotify extends NodeControlMessage {
  static const typeName = 'notify';

  /// The application-defined action name.
  final String action;

  /// The notification payload.
  final Map<String, dynamic> payload;

  /// Creates a one-way notification.
  const NodeNotify(this.action, {this.payload = const {}});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'action': action, 'payload': payload};

  /// Decodes from [json].
  static NodeNotify fromJson(Map<String, dynamic> json) => NodeNotify(
    Json.requireString(json, 'action'),
    payload: json['payload'] is Map ? Json.asObject(json['payload']) : const {},
  );
}

/// Node → hub: graceful shutdown notice.
@immutable
final class NodeGoodbye extends NodeControlMessage {
  static const typeName = 'goodbye';

  /// An optional human-readable reason.
  final String? reason;

  /// Creates a goodbye, optionally with a [reason].
  const NodeGoodbye([this.reason]);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {if (reason != null) 'reason': reason};

  /// Decodes from [json].
  static NodeGoodbye fromJson(Map<String, dynamic> json) =>
      NodeGoodbye(Json.optString(json, 'reason'));
}

/// Either direction: a protocol-level error.
@immutable
final class NodeErrorMessage extends NodeControlMessage {
  static const typeName = 'error';

  /// A stable error code.
  final String code;

  /// A human-readable message.
  final String message;

  /// The correlation id this error relates to, if any.
  final String? requestId;

  /// Creates an error message.
  const NodeErrorMessage(this.code, this.message, {this.requestId});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (requestId != null) 'requestId': requestId,
  };

  /// Decodes from [json].
  static NodeErrorMessage fromJson(Map<String, dynamic> json) =>
      NodeErrorMessage(
        Json.requireString(json, 'code'),
        Json.requireString(json, 'message'),
        requestId: Json.optString(json, 'requestId'),
      );
}
