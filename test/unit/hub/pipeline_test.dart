import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/fixed_clock.dart';

HubRequest req(String path) => HubRequest(
  method: 'GET',
  uri: Uri.parse('http://h$path'),
  protocol: TransportProtocol.http,
);

void main() {
  group('composePipeline', () {
    test('runs middleware outermost-first, innermost-last', () async {
      final order = <String>[];
      Middleware tag(String label) =>
          (inner) => (request) async {
            order.add('>$label');
            final res = await inner(request);
            order.add('<$label');
            return res;
          };
      final handler = composePipeline((r) async {
        order.add('handler');
        return HubResponse.text('ok');
      }, [tag('a'), tag('b')]);
      await handler(req('/'));
      expect(order, ['>a', '>b', 'handler', '<b', '<a']);
    });
  });

  group('errorMapper', () {
    test('maps HubException to its typed response', () async {
      final handler = errorMapper()(
        (_) async => throw const ForbiddenException('no'),
      );
      final res = await handler(req('/'));
      expect(res.statusCode, 403);
    });

    test('maps unexpected errors to 500', () async {
      final handler = errorMapper()((_) async => throw StateError('boom'));
      final res = await handler(req('/'));
      expect(res.statusCode, 500);
    });

    test('passes through successful responses', () async {
      final handler = errorMapper()((_) async => HubResponse.text('fine'));
      expect((await handler(req('/'))).statusCode, 200);
    });
  });

  group('logRequests', () {
    test('logs method, path and status', () async {
      final records = <Map<String, Object?>>[];
      final logger = _CapturingLogger(records);
      final clock = FixedClock(DateTime.utc(2026));
      final handler = logRequests(logger: logger, clock: clock)(
        (_) async => HubResponse.text('ok', statusCode: 201),
      );
      await handler(req('/things'));
      expect(records, hasLength(1));
      expect(records.single['path'], '/things');
      expect(records.single['status'], 201);
    });
  });
}

class _CapturingLogger implements Logger {
  final List<Map<String, Object?>> records;
  _CapturingLogger(this.records);

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) => records.add(context);

  @override
  void info(String message, {Map<String, Object?> context = const {}}) =>
      log(LogLevel.info, message, context: context);

  @override
  void debug(String message, {Map<String, Object?> context = const {}}) {}
  @override
  void warn(String message, {Map<String, Object?> context = const {}}) {}
  @override
  void error(String message, {Map<String, Object?> context = const {}}) {}
  @override
  Logger child(Map<String, Object?> context) => this;
}
