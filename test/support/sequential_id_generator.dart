import 'package:omnyhub/omnyhub.dart';

/// An [IdGenerator] producing deterministic, monotonic ids for tests
/// (`1`, `2`, ... or `<prefix>-1`, `<prefix>-2`, ...).
class SequentialIdGenerator implements IdGenerator {
  int _counter = 0;

  @override
  String next([String prefix = '']) {
    final n = ++_counter;
    return prefix.isEmpty ? '$n' : '$prefix-$n';
  }
}
