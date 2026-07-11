import 'dart:convert';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('Message', () {
    test('text factory and equality', () {
      const a = Message.text('hi');
      const b = TextMessage('hi');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isA<TextMessage>());
    });

    test('binary copies data and compares by content', () {
      final bytes = [1, 2, 3];
      final a = BinaryMessage(bytes);
      final b = Message.binary([1, 2, 3]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      bytes[0] = 99; // mutate source; message must be unaffected
      expect(a.data[0], 1);
    });

    test('binary decodes as UTF-8', () {
      final msg = BinaryMessage(utf8.encode('héllo'));
      expect(msg.asString, 'héllo');
    });

    test('different payloads are unequal', () {
      expect(const TextMessage('a'), isNot(const TextMessage('b')));
      expect(BinaryMessage([1]), isNot(BinaryMessage([2])));
      expect(BinaryMessage([1]), isNot(BinaryMessage([1, 2])));
    });

    test('exhaustive switch over sealed type', () {
      String describe(Message m) => switch (m) {
        TextMessage(:final data) => 'text:$data',
        BinaryMessage(:final data) => 'binary:${data.length}',
      };
      expect(describe(const Message.text('x')), 'text:x');
      expect(describe(Message.binary([0, 0])), 'binary:2');
    });
  });
}
