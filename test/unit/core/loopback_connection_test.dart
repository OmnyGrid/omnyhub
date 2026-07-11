import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/loopback_connection.dart';

void main() {
  group('LoopbackConnection', () {
    test('records sent messages', () {
      final conn = LoopbackConnection();
      conn.send(const Message.text('a'));
      expect(conn.sent, [const Message.text('a')]);
    });

    test('deliver simulates inbound in standalone mode', () async {
      final conn = LoopbackConnection();
      final received = conn.incoming.first;
      conn.deliver(const Message.text('in'));
      expect(await received, const Message.text('in'));
    });

    test('pair() wires both directions', () async {
      final (a, b) = LoopbackConnection.pair();
      final onB = b.incoming.first;
      final onA = a.incoming.first;
      a.send(const Message.text('a->b'));
      b.send(const Message.text('b->a'));
      expect(await onB, const Message.text('a->b'));
      expect(await onA, const Message.text('b->a'));
    });

    test('closing one end closes the peer and completes done', () async {
      final (a, b) = LoopbackConnection.pair();
      expect(a.isOpen, isTrue);
      await a.close();
      expect(a.isOpen, isFalse);
      await a.done; // completes
      await b.done; // peer close propagated
      expect(b.isOpen, isFalse);
    });

    test('send after close is dropped', () {
      final conn = LoopbackConnection();
      conn.close();
      conn.send(const Message.text('late'));
      expect(conn.sent, isEmpty);
    });
  });
}
