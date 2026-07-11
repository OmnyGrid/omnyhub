import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub_cli.dart';

/// The `omnyhub` demo CLI: launches a config-driven reverse-proxy / gateway.
///
/// Usage:
/// ```sh
/// omnyhub <config.json>
/// omnyhub --config <config.json>
/// ```
Future<void> main(List<String> args) async {
  final configPath = _parseArgs(args);
  if (configPath == null) {
    stderr.writeln('OmnyHub $omnyHubVersion');
    stderr.writeln('Usage: omnyhub <config.json>');
    exitCode = 64; // EX_USAGE
    return;
  }

  final file = File(configPath);
  if (!file.existsSync()) {
    stderr.writeln('Config file not found: $configPath');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final Map<String, dynamic> config;
  try {
    config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } on Object catch (e) {
    stderr.writeln('Invalid config JSON: $e');
    exitCode = 65; // EX_DATAERR
    return;
  }

  final logger = StructuredLogger();
  final OmnyHub hub;
  try {
    hub = await buildGateway(config, logger: logger);
    await hub.start();
  } on HubException catch (e) {
    stderr.writeln('Failed to start: ${e.message}');
    exitCode = 1;
    return;
  }

  stdout.writeln('OmnyHub $omnyHubVersion gateway started:');
  for (final transport in hub.transports) {
    stdout.writeln('  ${transport.protocol.name} on port ${transport.port}');
  }
  stdout.writeln('Press Ctrl-C to stop.');

  // Run until interrupted.
  final done = _awaitInterrupt();
  await done;
  stdout.writeln('\nShutting down...');
  await hub.stop();
}

String? _parseArgs(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--config' || arg == '-c') {
      if (i + 1 < args.length) return args[i + 1];
      return null;
    }
    if (!arg.startsWith('-')) return arg;
  }
  return null;
}

Future<void> _awaitInterrupt() {
  final completer = Completer<void>();
  late final StreamSubscription<ProcessSignal> sub;
  sub = ProcessSignal.sigint.watch().listen((_) {
    sub.cancel();
    if (!completer.isCompleted) completer.complete();
  });
  return completer.future;
}
