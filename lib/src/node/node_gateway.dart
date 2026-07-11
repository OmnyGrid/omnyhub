import 'dart:async';

import '../core/connection.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../service/service.dart';
import '../shared/errors/hub_exception.dart';
import '../shared/utils/clock.dart';
import '../shared/utils/id_generator.dart';
import '../shared/utils/logger.dart';
import 'heartbeat_monitor.dart';
import 'message_codec.dart';
import 'node_control_message.dart';
import 'node_descriptor.dart';
import 'node_id.dart';
import 'node_registry.dart';

/// The hub-side endpoint that nodes connect to.
///
/// A [Service] hosted on the hub at [mount] (default `/_node`): nodes open a
/// WebSocket to it, register, heartbeat, and can discover peers or answer
/// [NodeRequest] RPCs. Register it into a hub and use [discover]/[nodes] to find
/// workers and [request] to invoke actions on them:
///
/// ```dart
/// final gateway = NodeGateway();
/// await hub.registerService(gateway);
/// final workers = gateway.discover(capability: 'transcode');
/// final result = await gateway.request(workers.first.id, 'ping');
/// ```
class NodeGateway extends ServiceBase {
  /// The registry of connected nodes.
  final NodeRegistry registry;

  /// The control-message codec.
  final MessageCodec codec;

  /// The clock used for liveness timing.
  final Clock clock;

  /// The heartbeat interval advertised to nodes.
  final Duration heartbeatInterval;

  /// How long a node may go silent before being dropped.
  final Duration heartbeatTimeout;

  /// The hub identifier announced to nodes.
  final String hubId;

  /// Logger for gateway events.
  final Logger logger;

  final IdGenerator _ids;
  final bool _ownsRegistry;
  final Map<String, Completer<NodeResponse>> _pending = {};
  HeartbeatMonitor? _monitor;

  /// Creates a node gateway.
  NodeGateway({
    super.name = 'nodes',
    super.mount = '/_node',
    NodeRegistry? registry,
    MessageCodec? codec,
    this.clock = const SystemClock(),
    this.heartbeatInterval = const Duration(seconds: 10),
    this.heartbeatTimeout = const Duration(seconds: 30),
    this.logger = const NoopLogger(),
    String? hubId,
    IdGenerator? idGenerator,
  }) : registry = registry ?? NodeRegistry(),
       _ownsRegistry = registry == null,
       codec = codec ?? MessageCodec.standard(),
       _ids = idGenerator ?? RandomIdGenerator(),
       hubId = hubId ?? (idGenerator ?? RandomIdGenerator()).next('hub');

  /// Descriptors of all currently connected nodes.
  Iterable<NodeDescriptor> get nodes => registry.all.map((n) => n.descriptor);

  /// Discovers nodes matching a capability/label filter (see
  /// [NodeRegistry.discover]).
  List<NodeDescriptor> discover({
    String? capability,
    Map<String, String> labels = const {},
    bool onlineOnly = true,
  }) => registry.discover(
    capability: capability,
    labels: labels,
    onlineOnly: onlineOnly,
  );

  /// Invokes [action] on node [nodeId] over the control channel and awaits its
  /// [NodeResponse].
  ///
  /// Throws [NodeUnavailableException] if the node is not connected, or
  /// [HubTimeoutException] if it does not respond within [timeout].
  Future<NodeResponse> request(
    NodeId nodeId,
    String action, {
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final node = registry.byId(nodeId);
    if (node == null) {
      throw NodeUnavailableException('Node $nodeId is not connected');
    }
    final requestId = _ids.next('rpc');
    final completer = Completer<NodeResponse>();
    _pending[requestId] = completer;
    node.connection.send(
      codec.encode(NodeRequest(requestId, action, payload: payload)),
    );
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(requestId);
      throw HubTimeoutException('Node RPC to $nodeId timed out');
    }
  }

  @override
  Future<HubResponse> handle(HubRequest request) async {
    // The node endpoint is a WebSocket control channel; plain HTTP requests
    // get a small status document instead.
    return HubResponse.json({
      'hubId': hubId,
      'nodes': nodes.map((n) => n.toJson()).toList(),
    });
  }

  @override
  Future<void> start() async {
    _monitor = HeartbeatMonitor(
      registry: registry,
      clock: clock,
      timeout: heartbeatTimeout,
      onTimeout: _onNodeTimeout,
    )..start();
  }

  @override
  Future<void> stop() async {
    _monitor?.stop();
    _monitor = null;
    if (_ownsRegistry) await registry.close();
  }

  @override
  void handleConnection(Connection connection, HubRequest request) {
    RegisteredNode? node;

    connection.incoming.listen((message) {
      NodeControlMessage decoded;
      try {
        decoded = codec.decode(message);
      } on HubException catch (e) {
        connection.send(codec.encode(NodeErrorMessage(e.code, e.message)));
        return;
      }

      switch (decoded) {
        case NodeRegister(:final descriptor):
          node = registry.register(
            descriptor: descriptor,
            connection: connection,
            now: clock.now(),
            principal: request.principal,
          );
          connection.send(
            codec.encode(
              NodeRegistered(hubId, heartbeatInterval.inMilliseconds),
            ),
          );
          logger.info(
            'Node registered',
            context: {'node': descriptor.id.value},
          );
        case Heartbeat(:final seq):
          final current = node;
          if (current != null) {
            registry.recordHeartbeat(
              id: current.id,
              seq: seq,
              now: clock.now(),
            );
            connection.send(codec.encode(HeartbeatAck(seq)));
          }
        case NodeQuery(:final requestId, :final capability, :final labels):
          final results = registry.discover(
            capability: capability,
            labels: labels,
          );
          connection.send(codec.encode(NodeQueryResult(requestId, results)));
        case NodeResponse(:final requestId):
          _pending.remove(requestId)?.complete(decoded);
        case NodeGoodbye():
          final current = node;
          if (current != null) registry.remove(current.id);
          unawaited(connection.close());
        case NodeRegistered() ||
            HeartbeatAck() ||
            NodeQueryResult() ||
            NodeRequest() ||
            NodeErrorMessage():
          // Hub-directed message types the node should not send; ignore.
          break;
      }
    });

    unawaited(
      connection.done.then((_) {
        final current = node;
        if (current != null) registry.remove(current.id);
      }),
    );
  }

  void _onNodeTimeout(RegisteredNode node) {
    logger.warn('Node timed out', context: {'node': node.id.value});
    registry.markTimedOut(node.id);
    unawaited(node.connection.close());
    registry.remove(node.id);
  }
}
