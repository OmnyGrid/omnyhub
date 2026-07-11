import 'dart:math';

/// Generates unique identifiers for connections, nodes and requests.
///
/// Injected (rather than calling a global) so tests can supply a deterministic
/// generator; see `SequentialIdGenerator` in `test/support/`.
abstract interface class IdGenerator {
  /// Returns a fresh identifier, optionally namespaced with [prefix]
  /// (e.g. `conn`, `node`, `req`).
  String next([String prefix = '']);
}

/// The default [IdGenerator]: a per-process monotonic counter combined with
/// random entropy, so ids are unique within a process and unpredictable across
/// processes without requiring an external dependency.
class RandomIdGenerator implements IdGenerator {
  final Random _random;
  int _counter = 0;

  /// Creates a random id generator. Pass a seeded [random] for reproducible
  /// output in tests; defaults to [Random.secure].
  RandomIdGenerator([Random? random]) : _random = random ?? Random.secure();

  @override
  String next([String prefix = '']) {
    final seq = (_counter++).toRadixString(36);
    final rand = _random.nextInt(1 << 32).toRadixString(36);
    final id = '$seq$rand';
    return prefix.isEmpty ? id : '$prefix-$id';
  }
}
