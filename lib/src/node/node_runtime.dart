import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../core/connection_codec.dart';
import '../shared/errors/hub_exception.dart';
import '../shared/utils/id_generator.dart';
import '../shared/utils/logger.dart';
import '../transport/web_socket_connection.dart';
import 'message_codec.dart';
import 'node_control_message.dart';
import 'node_descriptor.dart';
import 'node_id.dart';

/// Handles a [NodeRequest] RPC from the hub, returning the response payload.
/// Throwing produces a failed [NodeResponse].
typedef NodeActionHandler =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> payload,
    );

/// The lifecycle state of a [NodeRuntime].
enum NodeState {
  /// Not connected.
  disconnected,

  /// Establishing the control connection.
  connecting,

  /// Connected; awaiting registration acknowledgement.
  registering,

  /// Registered and serving.
  ready,

  /// Waiting to reconnect after a drop.
  backoff,

  /// Stopped by the caller.
  stopped,
}

/// Exponential backoff with jitter for reconnection.
class ReconnectPolicy {
  /// The initial delay.
  final Duration initial;

  /// The maximum delay.
  final Duration max;

  /// The exponential growth factor.
  final double factor;

  final Random? _random;
  int _attempt = 0;

  /// Creates a reconnect policy. Pass a seeded [random] for deterministic
  /// jitter in tests.
  ReconnectPolicy({
    this.initial = const Duration(milliseconds: 500),
    this.max = const Duration(seconds: 30),
    this.factor = 2.0,
    Random? random,
  }) : _random = random;

  /// The next backoff delay, advancing the attempt counter.
  Duration nextDelay() {
    final baseMs = (initial.inMilliseconds * pow(factor, _attempt))
        .clamp(0, max.inMilliseconds)
        .toInt();
    _attempt++;
    final jitter = _random == null
        ? 0
        : _random.nextInt((baseMs ~/ 4).clamp(1, 1000));
    return Duration(milliseconds: baseMs + jitter);
  }

  /// Resets the backoff after a successful connection.
  void reset() => _attempt = 0;
}

/// Configuration for a [NodeRuntime].
class NodeConfig {
  /// The hub control endpoint (`ws://`/`wss://…/_node`).
  final Uri hubUri;

  /// This node's id.
  final NodeId nodeId;

  /// Advertised capabilities.
  final Set<String> capabilities;

  /// Discovery labels.
  final Map<String, String> labels;

  /// Free-form metadata.
  final Map<String, String> metadata;

  /// The node agent version string.
  final String agentVersion;

  /// Headers sent on the WebSocket upgrade (e.g. `Authorization`).
  final Map<String, dynamic> headers;

  /// Fallback heartbeat interval if the hub does not advertise one.
  final Duration heartbeatInterval;

  /// How long to wait for a registration acknowledgement.
  final Duration registerTimeout;

  /// The reconnection backoff policy.
  final ReconnectPolicy reconnect;

  /// TLS trust for `wss://` (e.g. a self-signed test cert).
  final SecurityContext? securityContext;

  /// Escape hatch for accepting a self-signed certificate.
  final bool Function(X509Certificate cert, String host, int port)?
  onBadCertificate;

  /// Handles [NodeRequest] RPCs from the hub, if the node serves any.
  final NodeActionHandler? onRequest;

  /// Creates a node configuration.
  NodeConfig({
    required this.hubUri,
    required this.nodeId,
    this.capabilities = const {},
    this.labels = const {},
    this.metadata = const {},
    this.agentVersion = 'unknown',
    this.headers = const {},
    this.heartbeatInterval = const Duration(seconds: 10),
    this.registerTimeout = const Duration(seconds: 10),
    ReconnectPolicy? reconnect,
    this.securityContext,
    this.onBadCertificate,
    this.onRequest,
  }) : reconnect = reconnect ?? ReconnectPolicy();

  /// The descriptor advertised at registration.
  NodeDescriptor get descriptor => NodeDescriptor(
    id: nodeId,
    capabilities: capabilities,
    labels: labels,
    metadata: metadata,
    agentVersion: agentVersion,
  );
}

/// A remote participant that connects out to a hub, registers, heartbeats, and
/// optionally answers RPCs — reconnecting with backoff on drops.
///
/// ```dart
/// final node = OmnyNode(NodeConfig(
///   hubUri: Uri.parse('ws://hub.local/_node'),
///   nodeId: NodeId('worker-1'),
///   capabilities: {'transcode'},
/// ));
/// await node.start();
/// ```
class NodeRuntime {
  /// The node's configuration.
  final NodeConfig config;

  /// The codec used on the control channel.
  final MessageCodec codec;

  /// Logger for lifecycle events.
  final Logger logger;

  final IdGenerator _ids;
  final StreamController<NodeState> _states =
      StreamController<NodeState>.broadcast();
  final Map<String, Completer<List<NodeDescriptor>>> _pendingQueries = {};

  NodeState _state = NodeState.disconnected;
  TypedConnection<NodeControlMessage>? _typed;
  Completer<NodeRegistered>? _registered;
  Timer? _heartbeatTimer;
  int _heartbeatSeq = 0;
  bool _stopped = false;
  Future<void>? _loop;

  /// Creates a node runtime.
  NodeRuntime(
    this.config, {
    MessageCodec? codec,
    this.logger = const NoopLogger(),
    IdGenerator? idGenerator,
  }) : codec = codec ?? MessageCodec.standard(),
       _ids = idGenerator ?? RandomIdGenerator();

  /// The current lifecycle state.
  NodeState get state => _state;

  /// A broadcast stream of state transitions.
  Stream<NodeState> get states => _states.stream;

  /// Whether the node is registered and serving.
  bool get isReady => _state == NodeState.ready;

  /// Starts the connect → register → heartbeat loop (with reconnection).
  Future<void> start() async {
    if (_loop != null) throw StateError('Node is already started');
    _stopped = false;
    _loop = _run();
  }

  /// Stops the node: sends a goodbye, closes the connection, and ends the loop.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final typed = _typed;
    if (typed != null && typed.isOpen) {
      typed.send(const NodeGoodbye('shutdown'));
      await typed.close();
    }
    await _loop;
    _loop = null;
    if (!_states.isClosed) await _states.close();
  }

  /// Discovers peer nodes via the hub (must be [isReady]).
  Future<List<NodeDescriptor>> discoverPeers({
    String? capability,
    Map<String, String> labels = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final typed = _typed;
    if (typed == null || _state != NodeState.ready) {
      throw const NodeUnavailableException('Node is not connected to a hub');
    }
    final requestId = _ids.next('q');
    final completer = Completer<List<NodeDescriptor>>();
    _pendingQueries[requestId] = completer;
    typed.send(NodeQuery(requestId, capability: capability, labels: labels));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingQueries.remove(requestId);
      throw const HubTimeoutException('Peer discovery timed out');
    }
  }

  Future<void> _run() async {
    while (!_stopped) {
      try {
        _setState(NodeState.connecting);
        final conn = await WebSocketConnection.connect(
          config.hubUri,
          headers: config.headers,
          securityContext: config.securityContext,
          onBadCertificate: config.onBadCertificate,
        );
        final typed = TypedConnection(conn, codec);
        _typed = typed;
        _setState(NodeState.registering);

        final registered = Completer<NodeRegistered>();
        _registered = registered;
        final sub = typed.incoming.listen(
          _onControl,
          onError: (Object _) {},
          cancelOnError: false,
        );

        typed.send(NodeRegister(config.descriptor));
        final ack = await registered.future.timeout(config.registerTimeout);

        config.reconnect.reset();
        _setState(NodeState.ready);
        _startHeartbeat(
          ack.heartbeatIntervalMs > 0
              ? Duration(milliseconds: ack.heartbeatIntervalMs)
              : config.heartbeatInterval,
        );

        await conn.done;
        await sub.cancel();
      } on Object catch (e) {
        logger.warn('Node connection failed', context: {'error': '$e'});
      } finally {
        _stopHeartbeat();
        _registered = null;
        _typed = null;
      }

      if (_stopped) break;
      _setState(NodeState.backoff);
      await Future<void>.delayed(config.reconnect.nextDelay());
    }
    _setState(NodeState.stopped);
  }

  void _onControl(NodeControlMessage decoded) {
    switch (decoded) {
      case NodeRegistered():
        if (_registered?.isCompleted == false) _registered!.complete(decoded);
      case HeartbeatAck():
        break;
      case NodeQueryResult(:final requestId, :final nodes):
        _pendingQueries.remove(requestId)?.complete(nodes);
      case NodeRequest():
        unawaited(_handleRequest(decoded));
      case NodeErrorMessage(:final code, :final message):
        logger.warn('Hub error', context: {'code': code, 'message': message});
      case NodeRegister() ||
          Heartbeat() ||
          NodeQuery() ||
          NodeResponse() ||
          NodeGoodbye():
        break; // node-directed or hub-inbound types; ignore
    }
  }

  Future<void> _handleRequest(NodeRequest request) async {
    final typed = _typed;
    if (typed == null) return;
    final handler = config.onRequest;
    if (handler == null) {
      typed.send(NodeResponse.failure(request.requestId, 'No request handler'));
      return;
    }
    try {
      final payload = await handler(request.action, request.payload);
      typed.send(NodeResponse(request.requestId, payload: payload));
    } on Object catch (e) {
      typed.send(NodeResponse.failure(request.requestId, '$e'));
    }
  }

  void _startHeartbeat(Duration interval) {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(interval, (_) {
      final typed = _typed;
      if (typed != null && typed.isOpen) {
        typed.send(Heartbeat(++_heartbeatSeq));
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _setState(NodeState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}

/// The node runtime, named to match the ecosystem's role-oriented API.
typedef OmnyNode = NodeRuntime;
