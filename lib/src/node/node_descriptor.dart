import '../shared/json/json.dart';
import 'node_id.dart';

/// The liveness status of a node.
enum NodeStatus {
  /// The node is connected and heartbeating.
  online,

  /// The node has disconnected or timed out.
  offline,

  /// Liveness is not yet known.
  unknown;

  /// Parses a wire value, defaulting to [unknown].
  static NodeStatus fromWire(String value) => NodeStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => NodeStatus.unknown,
  );
}

/// The public description of a node: identity, advertised capabilities, labels,
/// free-form metadata, agent version and liveness [status].
///
/// This is what a node announces on registration and what discovery queries
/// return. Immutable; use [copyWith] to derive updated descriptors.
class NodeDescriptor {
  /// The node's id.
  final NodeId id;

  /// Capability tokens the node advertises (e.g. `transcode`, `gpu`).
  final Set<String> capabilities;

  /// Key/value labels used for discovery filtering (e.g. `region=eu`).
  final Map<String, String> labels;

  /// Additional free-form metadata (not used for filtering).
  final Map<String, String> metadata;

  /// Structured, JSON-typed application data the node advertises (e.g. a nested
  /// service catalogue, an organisation id, a public key).
  ///
  /// Unlike [labels] and [metadata] — which are flat string→string maps — values
  /// here keep their JSON types and may nest. The built-in discovery filters
  /// ignore [attributes]; match on it with a custom `NodeMatcher` or the `where`
  /// predicate on `NodeRegistry.discover`.
  final Map<String, dynamic> attributes;

  /// The node agent's version string.
  final String agentVersion;

  /// The node's liveness status (maintained hub-side).
  final NodeStatus status;

  /// Creates a descriptor. Collections are copied into unmodifiable views.
  NodeDescriptor({
    required this.id,
    Set<String> capabilities = const {},
    Map<String, String> labels = const {},
    Map<String, String> metadata = const {},
    Map<String, dynamic> attributes = const {},
    this.agentVersion = 'unknown',
    this.status = NodeStatus.unknown,
  }) : capabilities = Set.unmodifiable(capabilities),
       labels = Map.unmodifiable(labels),
       metadata = Map.unmodifiable(metadata),
       attributes = Map.unmodifiable(attributes);

  /// Whether the node advertises [capability].
  bool hasCapability(String capability) => capabilities.contains(capability);

  /// Whether the node's labels contain every entry in [filter].
  bool matchesLabels(Map<String, String> filter) {
    for (final entry in filter.entries) {
      if (labels[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Returns a copy with the given fields replaced.
  NodeDescriptor copyWith({
    Set<String>? capabilities,
    Map<String, String>? labels,
    Map<String, String>? metadata,
    Map<String, dynamic>? attributes,
    String? agentVersion,
    NodeStatus? status,
  }) => NodeDescriptor(
    id: id,
    capabilities: capabilities ?? this.capabilities,
    labels: labels ?? this.labels,
    metadata: metadata ?? this.metadata,
    attributes: attributes ?? this.attributes,
    agentVersion: agentVersion ?? this.agentVersion,
    status: status ?? this.status,
  );

  /// Serialises the descriptor to a JSON map.
  ///
  /// [attributes] is omitted when empty, so descriptors that do not use it
  /// serialise exactly as before.
  Map<String, dynamic> toJson() => {
    'id': id.value,
    'capabilities': capabilities.toList()..sort(),
    'labels': labels,
    'metadata': metadata,
    if (attributes.isNotEmpty) 'attributes': attributes,
    'agentVersion': agentVersion,
    'status': status.name,
  };

  /// Parses a descriptor from a JSON map.
  factory NodeDescriptor.fromJson(Map<String, dynamic> json) => NodeDescriptor(
    id: NodeId(Json.requireString(json, 'id')),
    capabilities: Json.optStringList(json, 'capabilities').toSet(),
    labels: Json.optStringMap(json, 'labels'),
    metadata: Json.optStringMap(json, 'metadata'),
    attributes: Json.optObject(json, 'attributes'),
    agentVersion: Json.optString(json, 'agentVersion', 'unknown')!,
    status: NodeStatus.fromWire(Json.optString(json, 'status', 'unknown')!),
  );

  @override
  String toString() =>
      'NodeDescriptor($id, ${status.name}, caps: ${capabilities.join(',')})';
}
