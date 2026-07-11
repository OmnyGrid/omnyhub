import 'dart:math';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/fixed_clock.dart';
import '../../support/sequential_id_generator.dart';

void main() {
  group('Clock', () {
    test('SystemClock returns UTC now', () {
      expect(const SystemClock().now().isUtc, isTrue);
    });

    test('FixedClock is deterministic and advanceable', () {
      final clock = FixedClock(DateTime.utc(2026, 1, 1));
      expect(clock.now(), DateTime.utc(2026, 1, 1));
      clock.advance(const Duration(hours: 2));
      expect(clock.now(), DateTime.utc(2026, 1, 1, 2));
    });
  });

  group('IdGenerator', () {
    test('RandomIdGenerator produces unique, prefixed ids', () {
      final gen = RandomIdGenerator(Random(42));
      final ids = {for (var i = 0; i < 1000; i++) gen.next('conn')};
      expect(ids, hasLength(1000));
      expect(ids.every((id) => id.startsWith('conn-')), isTrue);
    });

    test('empty prefix omits the dash', () {
      final gen = RandomIdGenerator(Random(1));
      expect(gen.next(), isNot(startsWith('-')));
    });

    test('SequentialIdGenerator is monotonic', () {
      final gen = SequentialIdGenerator();
      expect(gen.next('node'), 'node-1');
      expect(gen.next('node'), 'node-2');
      expect(gen.next(), '3');
    });
  });

  group('LogLevel', () {
    test('severity ordering', () {
      expect(LogLevel.error >= LogLevel.info, isTrue);
      expect(LogLevel.debug >= LogLevel.warn, isFalse);
    });
  });

  group('NoopLogger', () {
    test('discards without throwing and child returns self', () {
      const logger = NoopLogger();
      logger.info('ignored', context: {'k': 'v'});
      expect(logger.child({'a': 'b'}), same(logger));
    });
  });
}
