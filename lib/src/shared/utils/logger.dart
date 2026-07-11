import 'dart:convert';
import 'dart:io';

/// Severity levels for [Logger].
enum LogLevel {
  /// Fine-grained diagnostic detail.
  debug,

  /// Normal operational events.
  info,

  /// Recoverable problems worth attention.
  warn,

  /// Failures.
  error;

  /// Whether this level is at least as severe as [other].
  bool operator >=(LogLevel other) => index >= other.index;
}

/// Structured logging port.
///
/// Libraries default to [NoopLogger] — logging is opt-in, so embedding OmnyHub
/// never writes to stdout/stderr unless the application asks for it. Use
/// [child] to bind scoped base context that is merged into every record.
abstract interface class Logger {
  /// Emits a log record at [level] with [message] and optional [context].
  void log(LogLevel level, String message, {Map<String, Object?> context});

  /// Convenience for [LogLevel.debug].
  void debug(String message, {Map<String, Object?> context});

  /// Convenience for [LogLevel.info].
  void info(String message, {Map<String, Object?> context});

  /// Convenience for [LogLevel.warn].
  void warn(String message, {Map<String, Object?> context});

  /// Convenience for [LogLevel.error].
  void error(String message, {Map<String, Object?> context});

  /// Returns a logger that merges [context] into every record it emits.
  Logger child(Map<String, Object?> context);
}

/// A [Logger] that discards everything. The default throughout the framework.
class NoopLogger implements Logger {
  /// Creates a no-op logger.
  const NoopLogger();

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) {}

  @override
  void debug(String message, {Map<String, Object?> context = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> context = const {}}) {}

  @override
  void warn(String message, {Map<String, Object?> context = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> context = const {}}) {}

  @override
  Logger child(Map<String, Object?> context) => this;
}

/// A [Logger] that writes one JSON object per line to an [IOSink]
/// (stderr by default), filtering records below [minLevel].
class StructuredLogger implements Logger {
  /// The sink records are written to.
  final IOSink sink;

  /// The minimum level emitted; lower-severity records are dropped.
  final LogLevel minLevel;

  final Map<String, Object?> _base;

  /// Creates a structured logger writing to [sink] (defaults to stderr).
  StructuredLogger({
    IOSink? sink,
    this.minLevel = LogLevel.info,
    Map<String, Object?> base = const {},
  }) : sink = sink ?? stderr,
       _base = base;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    if (!(level >= minLevel)) return;
    sink.writeln(
      jsonEncode({
        'level': level.name,
        'message': message,
        ..._base,
        ...context,
      }),
    );
  }

  @override
  void debug(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.debug, message, context: context);

  @override
  void info(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.info, message, context: context);

  @override
  void warn(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.warn, message, context: context);

  @override
  void error(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.error, message, context: context);

  @override
  Logger child(Map<String, Object?> context) => StructuredLogger(
    sink: sink,
    minLevel: minLevel,
    base: {..._base, ...context},
  );
}
