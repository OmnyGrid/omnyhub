import '../shared/errors/hub_exception.dart';

/// A validated node identifier (slug-like: letters, digits, `.`, `_`, `-`).
class NodeId {
  /// The raw identifier value.
  final String value;

  NodeId._(this.value);

  static final _pattern = RegExp(r'^[A-Za-z0-9._-]+$');

  /// Creates a node id, validating its format.
  ///
  /// Throws [ValidationException] if [value] is empty or contains characters
  /// outside `[A-Za-z0-9._-]`.
  factory NodeId(String value) {
    if (value.isEmpty || !_pattern.hasMatch(value)) {
      throw ValidationException('Invalid node id: "$value"');
    }
    return NodeId._(value);
  }

  @override
  bool operator ==(Object other) => other is NodeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
