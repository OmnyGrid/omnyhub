import 'dart:async';

import '../core/connection.dart';
import '../core/principal.dart';
import 'node_descriptor.dart';
import 'node_id.dart';

/// A node currently registered with the hub, with its live connection and
/// liveness bookkeeping.
class RegisteredNode {
  /// The node's public descriptor (mutable as status/labels change).
  NodeDescriptor descriptor;

  /// The control connection serving this node.
  final Connection connection;

  /// The authenticated principal behind the node connection, if any.
  final Principal? principal;

  /// An id identifying this connection/peer, for reverse lookup
  /// ([NodeRegistry.byConnectionId]). Assigned by the gateway on register.
  final String? connectionId;

  /// When the hub last heard from the node.
  DateTime lastSeen;

  /// The last accepted heartbeat sequence number.
  int lastHeartbeatSeq;

  /// Number of sessions currently routed to this node (application-maintained).
  int activeSessions;

  /// Scratch space for application-owned per-node state, keyed by the
  /// application (e.g. the last resource-metrics snapshot, a lease, a scheduler
  /// cursor).
  ///
  /// The registry constructs [RegisteredNode] itself, so subclassing it to add
  /// fields does not work — this bag is the seam instead. Nothing in omnyhub
  /// reads or writes it; entries live and die with the registration.
  final Map<String, Object?> state = {};

  /// Creates a registered-node record.
  RegisteredNode({
    required this.descriptor,
    required this.connection,
    required this.lastSeen,
    this.principal,
    this.connectionId,
    this.lastHeartbeatSeq = 0,
    this.activeSessions = 0,
  });

  /// The node's id.
  NodeId get id => descriptor.id;
}

/// The kind of a [NodeEvent].
enum NodeEventKind {
  /// A node registered (or re-registered).
  registered,

  /// A node was removed (goodbye or disconnect).
  removed,

  /// A node revised the descriptor it advertises.
  updated,

  /// A node was marked offline by the heartbeat monitor.
  timedOut,

  /// A node's connection dropped and its record was retained (marked offline
  /// rather than removed). Only emitted when the gateway retains nodes.
  disconnected,
}

/// An observable change in the [NodeRegistry].
class NodeEvent {
  /// What happened.
  final NodeEventKind kind;

  /// The affected node's descriptor.
  final NodeDescriptor descriptor;

  /// The affected registration, when the subscriber needs more than the
  /// descriptor — its [RegisteredNode.connection], [RegisteredNode.principal] or
  /// [RegisteredNode.state].
  ///
  /// Present for every event the registry emits; nullable so the const
  /// two-argument constructor keeps working.
  final RegisteredNode? node;

  /// Creates a node event.
  const NodeEvent(this.kind, this.descriptor, [this.node]);
}

/// Tracks the nodes registered with the hub and answers discovery queries.
///
/// Emits [events] for registration/removal/timeout so callers can react
/// (dashboards, tests, schedulers).
class NodeRegistry {
  final Map<String, RegisteredNode> _byId = {};
  final StreamController<NodeEvent> _events =
      StreamController<NodeEvent>.broadcast();

  /// All registered nodes.
  Iterable<RegisteredNode> get all => _byId.values;

  /// The number of registered nodes.
  int get length => _byId.length;

  /// A broadcast stream of registry changes.
  Stream<NodeEvent> get events => _events.stream;

  /// The node with [id], or `null`.
  RegisteredNode? byId(NodeId id) => _byId[id.value];

  /// The node whose [RegisteredNode.connectionId] equals [connectionId], or
  /// `null`.
  RegisteredNode? byConnectionId(String connectionId) {
    for (final node in _byId.values) {
      if (node.connectionId == connectionId) return node;
    }
    return null;
  }

  /// Registers (or replaces) a node from [descriptor], marking it online.
  RegisteredNode register({
    required NodeDescriptor descriptor,
    required Connection connection,
    required DateTime now,
    Principal? principal,
    String? connectionId,
  }) {
    final node = RegisteredNode(
      descriptor: descriptor.copyWith(status: NodeStatus.online),
      connection: connection,
      lastSeen: now,
      principal: principal,
      connectionId: connectionId,
    );
    _byId[descriptor.id.value] = node;
    _emit(NodeEventKind.registered, node);
    return node;
  }

  /// Sets the [activeSessions] count for node [id].
  void updateActiveSessions(NodeId id, int activeSessions) {
    final node = _byId[id.value];
    if (node != null) node.activeSessions = activeSessions;
  }

  /// Records an accepted heartbeat for node [id].
  void recordHeartbeat({
    required NodeId id,
    required int seq,
    required DateTime now,
  }) {
    final node = _byId[id.value];
    if (node != null) {
      node.lastHeartbeatSeq = seq;
      node.lastSeen = now;
    }
  }

  /// Removes node [id], returning the removed record (or `null`).
  RegisteredNode? remove(NodeId id) {
    final node = _byId.remove(id.value);
    if (node != null) _emit(NodeEventKind.removed, node);
    return node;
  }

  /// Marks node [id] offline because it stopped heartbeating (used by the
  /// heartbeat monitor).
  ///
  /// The record is kept, so an application that tracks node history can leave
  /// timed-out nodes in place rather than [remove]ing them. They are excluded
  /// from [discover] while `onlineOnly` is set.
  void markTimedOut(NodeId id) => _markOffline(id, NodeEventKind.timedOut);

  /// Marks node [id] offline because its connection dropped, keeping the record.
  ///
  /// The retaining counterpart of [remove]: same effect on [discover], but the
  /// node stays queryable by [byId] so its history and last-known descriptor
  /// survive the disconnect.
  void markOffline(NodeId id) => _markOffline(id, NodeEventKind.disconnected);

  void _markOffline(NodeId id, NodeEventKind kind) {
    final node = _byId[id.value];
    if (node == null) return;
    node.descriptor = node.descriptor.copyWith(status: NodeStatus.offline);
    _emit(kind, node);
  }

  /// Replaces the descriptor of node [id], preserving its connection and
  /// liveness bookkeeping. No-op if the node is unknown.
  ///
  /// Lets a node revise what it advertises (capabilities, labels, attributes)
  /// without re-registering. The [NodeStatus] is carried over from the existing
  /// record — liveness is the hub's to decide, not the node's.
  void updateDescriptor(NodeId id, NodeDescriptor descriptor) {
    final node = _byId[id.value];
    if (node == null) return;
    node.descriptor = descriptor.copyWith(status: node.descriptor.status);
    _emit(NodeEventKind.updated, node);
  }

  /// Returns descriptors matching the given filter.
  ///
  /// Filters by [capability] (if given), [labels] (all must match) and, when
  /// [onlineOnly] is true (the default), excludes offline nodes. Results are
  /// sorted by id for determinism.
  ///
  /// [where] is an additional application predicate, applied after the built-in
  /// filters — use it for query semantics the registry cannot know about
  /// (version ranges, nested catalogues in [NodeDescriptor.attributes]).
  List<NodeDescriptor> discover({
    String? capability,
    Map<String, String> labels = const {},
    bool Function(NodeDescriptor descriptor)? where,
    bool onlineOnly = true,
  }) {
    final result = <NodeDescriptor>[];
    for (final node in _byId.values) {
      final d = node.descriptor;
      if (onlineOnly && d.status != NodeStatus.online) continue;
      if (capability != null && !d.hasCapability(capability)) continue;
      if (!d.matchesLabels(labels)) continue;
      if (where != null && !where(d)) continue;
      result.add(d);
    }
    result.sort((a, b) => a.id.value.compareTo(b.id.value));
    return result;
  }

  /// Closes the event stream.
  Future<void> close() => _events.close();

  void _emit(NodeEventKind kind, RegisteredNode node) {
    if (!_events.isClosed) {
      _events.add(NodeEvent(kind, node.descriptor, node));
    }
  }
}
