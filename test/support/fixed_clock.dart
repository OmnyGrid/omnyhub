import 'package:omnyhub/omnyhub.dart';

/// A [Clock] returning a fixed, manually advanceable instant, for deterministic
/// timing in tests.
class FixedClock implements Clock {
  DateTime _now;

  /// Creates a clock fixed at [start] (coerced to UTC).
  FixedClock(DateTime start) : _now = start.toUtc();

  @override
  DateTime now() => _now;

  /// Advances the clock by [duration].
  void advance(Duration duration) => _now = _now.add(duration);

  /// Sets the clock to [instant] (coerced to UTC).
  void set(DateTime instant) => _now = instant.toUtc();
}
