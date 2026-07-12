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

/// Observes a [Heartbeat] from [node], after the gateway has recorded its
/// liveness and acked it.
///
/// The seam for telemetry a node piggy-backs on the beat via
/// [Heartbeat.payload] (a metrics snapshot, a queue depth). Keep it cheap — it
/// runs on every beat of every node.
typedef HeartbeatHandler = void Function(RegisteredNode node, Heartbeat beat);

/// Handles a [NodeNotify] pushed by [from] — a one-way message with no reply.
///
/// The fire-and-forget counterpart of [HubActionHandler]. Like node→hub RPC,
/// only registered nodes may push, so [from] is always a live registration.
typedef NotifyHandler =
    void Function(
      String action,
      Map<String, dynamic> payload,
      RegisteredNode from,
    );

/// Observes a node's control connection opening, before it registers.
///
/// Fires for *every* accepted connection, including one that never sends
/// [NodeRegister] — the registry's events cannot see those.
typedef NodeConnectHandler =
    void Function(Connection connection, HubRequest request);

/// Observes a node's control connection closing, before the gateway disposes of
/// the registration.
///
/// [node] is `null` if the connection dropped before it ever registered.
typedef NodeDisconnectHandler =
    void Function(RegisteredNode? node, Connection connection);

/// Observes a node being dropped by the heartbeat monitor, before the gateway
/// disposes of the registration.
typedef NodeTimeoutHandler = void Function(RegisteredNode node);

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

  /// Handles one-way [NodeNotify] pushes from nodes. When `null`, they are
  /// discarded.
  final NotifyHandler? onNotify;

  /// Observes every [Heartbeat], after liveness is recorded and the ack is sent.
  final HeartbeatHandler? onHeartbeat;

  /// Observes a control connection opening (before registration).
  final NodeConnectHandler? onConnect;

  /// Observes a control connection closing (before the registration is
  /// disposed of).
  final NodeDisconnectHandler? onDisconnect;

  /// Observes a node being dropped by the heartbeat monitor (before the
  /// registration is disposed of).
  final NodeTimeoutHandler? onTimeout;

  /// Whether a node that disconnects or times out is kept in the registry,
  /// marked offline, instead of being removed.
  ///
  /// `false` (the default) drops the record entirely: the registry only ever
  /// holds live nodes. Set it when the hub is the system of record for a known
  /// fleet — an offline node stays queryable by [NodeRegistry.byId] with its
  /// last-known descriptor, and re-registers into the same slot when it returns.
  /// Either way an offline node is excluded from [discover].
  final bool retainNodes;

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
    this.onNotify,
    this.onHeartbeat,
    this.onConnect,
    this.onDisconnect,
    this.onTimeout,
    this.retainNodes = false,
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

  /// Pushes a one-way [NodeNotify] to node [nodeId] — no correlation id, no
  /// reply. The mirror of `NodeRuntime.notify`.
  ///
  /// Best-effort: returns `false` if the node is not connected, and a notify
  /// lost in a dropping connection is not retried. Use [request] when the
  /// outcome matters.
  bool notify(
    NodeId nodeId,
    String action, {
    Map<String, dynamic> payload = const {},
  }) {
    final node = registry.byId(nodeId);
    if (node == null || !node.connection.isOpen) return false;
    node.connection.send(codec.encode(NodeNotify(action, payload: payload)));
    return true;
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

    // [onRegister] may do real async work (vetting a CSR, writing to a repo), and
    // a node starts heartbeating the moment it is acked. Frames that land while
    // registration is still settling are held here and replayed in order once it
    // does — otherwise they would race an unset `node` and be dropped
    // (Heartbeat, NodeUpdate) or refused as 'Not registered' (NodeRequest).
    final backlog = <NodeControlMessage>[];
    var registering = false;

    void dispatch(NodeControlMessage decoded) {
      switch (decoded) {
        case NodeRegister():
          // A second register on an already-registered connection re-admits the
          // node; the registry replaces the record under the same id.
          registering = true;
          unawaited(
            _register(decoded, connection, request).then((admitted) {
              node = admitted;
              registering = false;
              final queued = List.of(backlog);
              backlog.clear();
              // A rejected registration has already closed the connection.
              if (admitted != null) queued.forEach(dispatch);
            }),
          );
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
            onHeartbeat?.call(current, decoded);
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
          unawaited(_serveRequest(decoded, connection, node));
        case NodeResponse(:final requestId):
          _pending.remove(requestId)?.completer.complete(decoded);
        case NodeNotify(:final action, :final payload):
          // One-way push. Like node→hub RPC, only registered nodes may send —
          // but there is no reply, so an unregistered one is simply dropped.
          final current = node;
          if (current != null) onNotify?.call(action, payload, current);
        case NodeGoodbye():
          final current = node;
          if (current != null) {
            _failPendingFor(current.id, 'Node ${current.id} said goodbye');
            _dispose(current);
          }
          unawaited(connection.close());
        case NodeRegistered() ||
            HeartbeatAck() ||
            NodeQueryResult() ||
            NodeErrorMessage():
          // Hub-directed message types the node should not send; ignore.
          break;
      }
    }

    onConnect?.call(connection, request);

    connection.incoming.listen((message) {
      NodeControlMessage decoded;
      try {
        decoded = codec.decode(message);
      } on HubException catch (e) {
        connection.send(codec.encode(NodeErrorMessage(e.code, e.message)));
        return;
      } on Object catch (e) {
        // A codec that raises something other than a HubException must not
        // escape this listener as an uncaught async error and tear down the
        // isolate — answer the peer and keep serving.
        logger.warn('Control message decode failed', context: {'error': '$e'});
        connection.send(
          codec.encode(
            NodeErrorMessage(
              ErrorCodes.protocolError,
              'Malformed control message',
            ),
          ),
        );
        return;
      }

      if (registering && decoded is! NodeRegister) {
        backlog.add(decoded);
        return;
      }
      dispatch(decoded);
    });

    unawaited(
      connection.done.then((_) {
        final current = node;
        onDisconnect?.call(current, connection);
        if (current != null) {
          _failPendingFor(current.id, 'Node ${current.id} disconnected');
          _dispose(current);
        }
      }),
    );
  }

  /// Disposes of a registration whose connection is gone: removed outright, or
  /// retained and marked offline when [retainNodes] is set.
  void _dispose(RegisteredNode node) {
    if (retainNodes) {
      registry.markOffline(node.id);
    } else {
      registry.remove(node.id);
    }
  }

  /// Admits a node: runs [onRegister] (if any), then enters it into the
  /// registry and acks with [NodeRegistered]. Returns the registration, or
  /// `null` if it was rejected.
  ///
  /// A rejecting handler sends [NodeErrorMessage] and closes the connection —
  /// the node is never registered, so it is never discoverable and never
  /// heartbeats.
  Future<RegisteredNode?> _register(
    NodeRegister message,
    Connection connection,
    HubRequest request,
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
        await connection.close(WsCloseCodes.forException(e), e.message);
        return null;
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
        return null;
      }
    }

    final node = registry.register(
      descriptor: descriptor,
      connection: connection,
      now: clock.now(),
      principal: request.principal,
      connectionId: _ids.next('conn'),
    );
    connection.send(
      codec.encode(
        NodeRegistered(hubId, heartbeatInterval.inMilliseconds, payload: ack),
      ),
    );
    logger.info('Node registered', context: {'node': descriptor.id.value});
    return node;
  }

  /// Answers an inbound [NodeRequest] with exactly one [NodeResponse] — a
  /// handler that throws yields a failed response rather than leaving the node
  /// waiting for its timeout.
  ///
  /// Unregistered callers are turned away here, so [onRequest] only ever sees a
  /// registered node and never has to guess whether it can trust the caller.
  Future<void> _serveRequest(
    NodeRequest request,
    Connection connection,
    RegisteredNode? from,
  ) async {
    void fail(String error) => connection.send(
      codec.encode(NodeResponse.failure(request.requestId, error)),
    );

    final handler = onRequest;
    if (handler == null) {
      fail('No request handler');
      return;
    }
    if (from == null) {
      fail('Not registered');
      return;
    }
    try {
      final payload = await handler(request.action, request.payload, from);
      connection.send(
        codec.encode(NodeResponse(request.requestId, payload: payload)),
      );
    } on Object catch (e) {
      fail('$e');
    }
  }

  void _onNodeTimeout(RegisteredNode node) {
    logger.warn('Node timed out', context: {'node': node.id.value});
    onTimeout?.call(node);
    _failPendingFor(node.id, 'Node ${node.id} timed out');
    registry.markTimedOut(node.id);
    unawaited(node.connection.close());
    if (!retainNodes) registry.remove(node.id);
  }
}
