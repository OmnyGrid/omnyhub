import 'dart:async';

import '../core/connection.dart';
import '../core/connection_codec.dart';
import '../core/principal.dart';
import '../core/ws_close.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../service/service.dart';
import '../shared/errors/error_codes.dart';
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

/// Handles a [NodeRequest] a *node* sent to the *hub*, returning the response
/// payload. Throwing produces a failed [NodeResponse].
///
/// [from] is the node that issued the call. Registration is a precondition for
/// node→hub RPC — the gateway rejects requests from unregistered connections
/// before reaching this handler — so [from] is always a live, registered node
/// and its [RegisteredNode.principal] can be trusted for authorization.
typedef HubActionHandler =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> payload,
      RegisteredNode from,
    );

/// Decides whether a node registration is accepted, and what to send back.
///
/// Called on [NodeRegister] before the node enters the registry. Return the
/// payload for the [NodeRegistered] ack (`const {}` for none) — this is where an
/// application enrols the node: validate its [NodeRegister.payload] (a CSR, an
/// enrolment secret), and hand back what it needs (a signed certificate, a
/// lease).
///
/// Throw a [HubException] to **reject**: the hub replies [NodeErrorMessage] and
/// closes the connection without registering.
typedef NodeRegistrationHandler =
    Future<Map<String, dynamic>> Function(
      NodeDescriptor descriptor,
      Map<String, dynamic> payload,
      Principal? principal,
    );

/// Matches a node against an application-defined [NodeQuery.filter].
///
/// The built-in discovery filters are flat — a capability token and exact-match
/// string labels. Implement this when queries need semantics the hub cannot know
/// about (version ranges, nested service catalogues held in
/// [NodeDescriptor.attributes]).
abstract interface class NodeMatcher {
  /// Whether [node] satisfies [filter].
  bool matches(NodeDescriptor node, Map<String, dynamic> filter);
}

/// A hub→node RPC awaiting its [NodeResponse].
class _PendingRpc {
  final NodeId nodeId;
  final Completer<NodeResponse> completer;

  _PendingRpc(this.nodeId, this.completer);
}

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
  ///
  /// Defaults to [MessageCodec.standard] (a JSON envelope). Any
  /// [ConnectionCodec] over [NodeControlMessage] works, so an application can
  /// swap in its own wire format (e.g. a binary one) without forking the
  /// gateway.
  final ConnectionCodec<NodeControlMessage> codec;

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

  /// Handles [NodeRequest]s sent *by nodes to this hub*, if the hub serves any.
  ///
  /// The mirror of `NodeRuntime.request`: nodes call up to the hub, and this
  /// handler answers. Leave `null` if the hub exposes no node-callable actions —
  /// inbound requests are then rejected with a failed [NodeResponse].
  ///
  /// Only registered nodes may call: a request arriving before [NodeRegister] is
  /// rejected without reaching the handler. Pre-registration exchange belongs in
  /// the connection handshake (`ConnectionAuthenticator`) or in the registration
  /// payloads themselves.
  final HubActionHandler? onRequest;

  /// Vets node registrations, if the hub enrols nodes.
  ///
  /// When `null`, every node that sends [NodeRegister] is accepted with an empty
  /// ack payload (the default, unchanged behaviour).
  final NodeRegistrationHandler? onRegister;

  /// Interprets [NodeQuery.filter], if the hub supports application-defined
  /// discovery. When `null`, `filter` is ignored.
  final NodeMatcher? matcher;

  final IdGenerator _ids;
  final bool _ownsRegistry;
  final Map<String, _PendingRpc> _pending = {};
  HeartbeatMonitor? _monitor;

  /// Creates a node gateway.
  NodeGateway({
    super.name = 'nodes',
    super.mount = '/_node',
    NodeRegistry? registry,
    ConnectionCodec<NodeControlMessage>? codec,
    this.clock = const SystemClock(),
    this.heartbeatInterval = const Duration(seconds: 10),
    this.heartbeatTimeout = const Duration(seconds: 30),
    this.logger = const NoopLogger(),
    this.onRequest,
    this.onRegister,
    this.matcher,
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
    _pending[requestId] = _PendingRpc(nodeId, completer);
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

  /// Fails every in-flight RPC to [nodeId], so callers get a prompt
  /// [NodeUnavailableException] instead of hanging until their timeout when the
  /// node drops.
  void _failPendingFor(NodeId nodeId, String reason) {
    _pending.removeWhere((_, pending) {
      if (pending.nodeId != nodeId) return false;
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(NodeUnavailableException(reason));
      }
      return true;
    });
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
        case NodeRegister():
          unawaited(_register(decoded, connection, request, (n) => node = n));
        case NodeUpdate(:final descriptor):
          final current = node;
          if (current != null) {
            registry.updateDescriptor(current.id, descriptor);
          }
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
        case NodeQuery(
          :final requestId,
          :final capability,
          :final labels,
          :final filter,
        ):
          final matcher = this.matcher;
          final results = registry.discover(
            capability: capability,
            labels: labels,
            where: matcher == null || filter.isEmpty
                ? null
                : (d) => matcher.matches(d, filter),
          );
          connection.send(codec.encode(NodeQueryResult(requestId, results)));
        case NodeRequest():
          // A node calling *up* to the hub. Symmetric with [request]: the node
          // sends NodeRequest, we answer NodeResponse.
          unawaited(_serveRequest(decoded, connection, () => node));
        case NodeResponse(:final requestId):
          _pending.remove(requestId)?.completer.complete(decoded);
        case NodeGoodbye():
          final current = node;
          if (current != null) {
            _failPendingFor(current.id, 'Node ${current.id} said goodbye');
            registry.remove(current.id);
          }
          unawaited(connection.close());
        case NodeRegistered() ||
            HeartbeatAck() ||
            NodeQueryResult() ||
            NodeErrorMessage():
          // Hub-directed message types the node should not send; ignore.
          break;
      }
    });

    unawaited(
      connection.done.then((_) {
        final current = node;
        if (current != null) {
          _failPendingFor(current.id, 'Node ${current.id} disconnected');
          registry.remove(current.id);
        }
      }),
    );
  }

  /// Admits a node: runs [onRegister] (if any), then enters it into the
  /// registry and acks with [NodeRegistered].
  ///
  /// A rejecting handler sends [NodeErrorMessage] and closes the connection —
  /// the node is never registered, so it is never discoverable and never
  /// heartbeats.
  Future<void> _register(
    NodeRegister message,
    Connection connection,
    HubRequest request,
    void Function(RegisteredNode) admit,
  ) async {
    final descriptor = message.descriptor;
    final handler = onRegister;

    var ack = const <String, dynamic>{};
    if (handler != null) {
      try {
        ack = await handler(descriptor, message.payload, request.principal);
      } on HubException catch (e) {
        logger.warn(
          'Node registration rejected',
          context: {'node': descriptor.id.value, 'code': e.code},
        );
        connection.send(codec.encode(NodeErrorMessage(e.code, e.message)));
        await connection.close(_wsCodeFor(e), e.message);
        return;
      } on Object catch (e) {
        logger.error(
          'Node registration handler failed',
          context: {'node': descriptor.id.value, 'error': '$e'},
        );
        connection.send(
          codec.encode(
            NodeErrorMessage(ErrorCodes.internalError, 'Registration failed'),
          ),
        );
        await connection.close(
          WsCloseCodes.unauthorized,
          'Registration failed',
        );
        return;
      }
    }

    admit(
      registry.register(
        descriptor: descriptor,
        connection: connection,
        now: clock.now(),
        principal: request.principal,
        connectionId: _ids.next('conn'),
      ),
    );
    connection.send(
      codec.encode(
        NodeRegistered(hubId, heartbeatInterval.inMilliseconds, payload: ack),
      ),
    );
    logger.info('Node registered', context: {'node': descriptor.id.value});
  }

  static int _wsCodeFor(HubException e) => switch (e.statusCode) {
    401 => WsCloseCodes.unauthorized,
    403 => WsCloseCodes.forbidden,
    404 => WsCloseCodes.notFound,
    _ => WsCloseCodes.unauthorized,
  };

  /// Answers an inbound [NodeRequest] with exactly one [NodeResponse] — a
  /// handler that throws yields a failed response rather than leaving the node
  /// waiting for its timeout.
  ///
  /// Unregistered callers are turned away here, so [onRequest] only ever sees a
  /// registered node and never has to guess whether it can trust the caller.
  Future<void> _serveRequest(
    NodeRequest request,
    Connection connection,
    RegisteredNode? Function() from,
  ) async {
    void fail(String error) => connection.send(
      codec.encode(NodeResponse.failure(request.requestId, error)),
    );

    final handler = onRequest;
    if (handler == null) {
      fail('No request handler');
      return;
    }
    final node = from();
    if (node == null) {
      fail('Not registered');
      return;
    }
    try {
      final payload = await handler(request.action, request.payload, node);
      connection.send(
        codec.encode(NodeResponse(request.requestId, payload: payload)),
      );
    } on Object catch (e) {
      fail('$e');
    }
  }

  void _onNodeTimeout(RegisteredNode node) {
    logger.warn('Node timed out', context: {'node': node.id.value});
    _failPendingFor(node.id, 'Node ${node.id} timed out');
    registry.markTimedOut(node.id);
    unawaited(node.connection.close());
    registry.remove(node.id);
  }
}
