import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/loopback_connection.dart';

/// A frame-style value: a text control frame or a binary data frame — the shape
/// omnyshell's protocol uses, exercised here to prove the pattern.
sealed class Frame {}

class Control extends Frame {
  final String type;
  Control(this.type);
}

class Data extends Frame {
  final List<int> bytes;
  Data(this.bytes);
}

/// A [ConnectionCodec] mapping text->Control and binary->Data, mirroring how a
/// FrameCodec rides on a raw connection.
class FrameCodec implements ConnectionCodec<Frame> {
  @override
  Message encode(Frame value) => switch (value) {
    Control(:final type) => TextMessage(jsonEncode({'t': type})),
    Data(:final bytes) => BinaryMessage(bytes),
  };

  @override
  Frame decode(Message message) => switch (message) {
    TextMessage(:final data) => Control(jsonDecode(data)['t'] as String),
    BinaryMessage(:final data) => Data(data),
  };
}

void main() {
  group('MessageCodec is a ConnectionCodec', () {
    test(
      'node MessageCodec implements ConnectionCodec<NodeControlMessage>',
      () {
        final ConnectionCodec<NodeControlMessage> codec =
            MessageCodec.standard();
        final msg = codec.decode(codec.encode(const Heartbeat(3)));
        expect(msg, isA<Heartbeat>());
        expect((msg as Heartbeat).seq, 3);
      },
    );
  });

  group('TypedConnection', () {
    test('round-trips text and binary frames through a codec', () async {
      final (a, b) = LoopbackConnection.pair();
      final ta = TypedConnection<Frame>(a, FrameCodec());
      final tb = TypedConnection<Frame>(b, FrameCodec());

      final received = <Frame>[];
      final sub = tb.incoming.listen(received.add);

      ta.send(Control('hello'));
      ta.send(Data(Uint8List.fromList([1, 2, 3])));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect((received[0] as Control).type, 'hello');
      expect((received[1] as Data).bytes, [1, 2, 3]);

      await sub.cancel();
      await ta.close();
    });

    test('drops undecodable frames without tearing down', () async {
      final (a, b) = LoopbackConnection.pair();
      final tb = TypedConnection<Frame>(b, FrameCodec());
      final received = <Frame>[];
      final sub = tb.incoming.listen(received.add);

      // Raw send of a non-JSON text frame => codec throws => dropped.
      a.send(const TextMessage('not-json'));
      a.send(
        TypedConnection<Frame>(a, FrameCodec()).codec.encode(Control('ok')),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect((received.single as Control).type, 'ok');

      await sub.cancel();
      await a.close();
    });

    test('exposes lifecycle of the underlying connection', () async {
      final conn = LoopbackConnection();
      final typed = TypedConnection<Frame>(conn, FrameCodec());
      expect(typed.isOpen, isTrue);
      expect(typed.remoteAddress, conn.remoteAddress);
      await typed.close();
      expect(typed.isOpen, isFalse);
      await typed.done;
    });
  });
}
