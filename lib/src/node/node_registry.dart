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

  /// When the hub last heard from the node.
  DateTime lastSeen;

  /// The last accepted heartbeat sequence number.
  int lastHeartbeatSeq;

  /// Creates a registered-node record.
  RegisteredNode({
    required this.descriptor,
    required this.connection,
    required this.lastSeen,
    this.principal,
    this.lastHeartbeatSeq = 0,
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

  /// A node was marked offline by the heartbeat monitor.
  timedOut,
}

/// An observable change in the [NodeRegistry].
class NodeEvent {
  /// What happened.
  final NodeEventKind kind;

  /// The affected node's descriptor.
  final NodeDescriptor descriptor;

  /// Creates a node event.
  const NodeEvent(this.kind, this.descriptor);
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

  /// Registers (or replaces) a node from [descriptor], marking it online.
  RegisteredNode register({
    required NodeDescriptor descriptor,
    required Connection connection,
    required DateTime now,
    Principal? principal,
  }) {
    final node = RegisteredNode(
      descriptor: descriptor.copyWith(status: NodeStatus.online),
      connection: connection,
      lastSeen: now,
      principal: principal,
    );
    _byId[descriptor.id.value] = node;
    _emit(NodeEventKind.registered, node.descriptor);
    return node;
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
    if (node != null) _emit(NodeEventKind.removed, node.descriptor);
    return node;
  }

  /// Marks node [id] offline (used by the heartbeat monitor).
  void markTimedOut(NodeId id) {
    final node = _byId[id.value];
    if (node == null) return;
    node.descriptor = node.descriptor.copyWith(status: NodeStatus.offline);
    _emit(NodeEventKind.timedOut, node.descriptor);
  }

  /// Returns descriptors matching the given filter.
  ///
  /// Filters by [capability] (if given), [labels] (all must match) and, when
  /// [onlineOnly] is true (the default), excludes offline nodes. Results are
  /// sorted by id for determinism.
  List<NodeDescriptor> discover({
    String? capability,
    Map<String, String> labels = const {},
    bool onlineOnly = true,
  }) {
    final result = <NodeDescriptor>[];
    for (final node in _byId.values) {
      final d = node.descriptor;
      if (onlineOnly && d.status != NodeStatus.online) continue;
      if (capability != null && !d.hasCapability(capability)) continue;
      if (!d.matchesLabels(labels)) continue;
      result.add(d);
    }
    result.sort((a, b) => a.id.value.compareTo(b.id.value));
    return result;
  }

  /// Closes the event stream.
  Future<void> close() => _events.close();

  void _emit(NodeEventKind kind, NodeDescriptor descriptor) {
    if (!_events.isClosed) _events.add(NodeEvent(kind, descriptor));
  }
}
