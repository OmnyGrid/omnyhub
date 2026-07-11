/// Time source used throughout OmnyHub so tests can fix `now`.
///
/// Heartbeat watchdogs, renewal schedulers and timeouts depend on a [Clock]
/// rather than calling [DateTime.now] directly, which keeps their behaviour
/// deterministic under test.
abstract interface class Clock {
  /// The current instant, in UTC.
  DateTime now();
}

/// The default [Clock], backed by the system wall clock (UTC).
class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}
