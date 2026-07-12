@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// Round-trips [message] through a standard codec, as the wire would.
NodeControlMessage roundTrip(NodeControlMessage message) =>
    MessageCodec.standard().decode(MessageCodec.standard().encode(message));

/// The JSON envelope a standard codec puts on the wire for [message].
Map<String, dynamic> envelopeOf(NodeControlMessage message) {
  final encoded = MessageCodec.standard().encode(message) as TextMessage;
  return jsonDecode(encoded.data) as Map<String, dynamic>;
}

void main() {
  group('Heartbeat payload', () {
    test('round-trips application data piggy-backed on the beat', () {
      final decoded =
          roundTrip(
                const Heartbeat(
                  7,
                  payload: {
                    'cpu': 0.42,
                    'memory': {'usedBytes': 1024},
                  },
                ),
              )
              as Heartbeat;

      expect(decoded.seq, 7);
      expect(decoded.payload['cpu'], 0.42);
      expect((decoded.payload['memory'] as Map)['usedBytes'], 1024);
    });

    test('omits the payload key entirely when empty', () {
      // Wire-compatibility with 1.2.0 peers: a beat with no telemetry must look
      // exactly like the beat they already send.
      expect(envelopeOf(const Heartbeat(1)), {'t': 'heartbeat', 'seq': 1});
    });

    test('decodes a beat from a peer that sends no payload', () {
      final legacy = TextMessage(jsonEncode({'t': 'heartbeat', 'seq': 3}));
      final decoded = MessageCodec.standard().decode(legacy) as Heartbeat;

      expect(decoded.seq, 3);
      expect(decoded.payload, isEmpty);
    });
  });

  group('NodeNotify', () {
    test('round-trips action and payload', () {
      final decoded =
          roundTrip(
                const NodeNotify(
                  'logs',
                  payload: {
                    'lines': ['a', 'b'],
                  },
                ),
              )
              as NodeNotify;

      expect(decoded.action, 'logs');
      expect(decoded.payload['lines'], ['a', 'b']);
    });

    test('carries no correlation id — it is one-way by construction', () {
      expect(envelopeOf(const NodeNotify('ping')), {
        't': 'notify',
        'action': 'ping',
        'payload': <String, dynamic>{},
      });
    });
  });

  group('decode failures surface as HubException', () {
    test('a non-UTF-8 binary frame raises ProtocolException, not '
        'FormatException', () {
      // Regression: `BinaryMessage.asString` used to run outside the codec's
      // guard, so arbitrary bytes escaped as a raw FormatException and took down
      // the gateway's listener as an uncaught async error.
      final garbage = BinaryMessage(
        Uint8List.fromList([0xC3, 0x28, 0xA0, 0xFF]),
      );

      expect(
        () => MessageCodec.standard().decode(garbage),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('malformed JSON raises ProtocolException', () {
      expect(
        () => MessageCodec.standard().decode(const TextMessage('{not json')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('an unknown message type raises ProtocolException', () {
      final unknown = TextMessage(jsonEncode({'t': 'no_such_type'}));

      expect(
        () => MessageCodec.standard().decode(unknown),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a binary frame that happens to carry UTF-8 JSON still decodes', () {
      final json = jsonEncode({'t': 'heartbeat', 'seq': 9});
      final binary = BinaryMessage(utf8.encode(json));

      expect((MessageCodec.standard().decode(binary) as Heartbeat).seq, 9);
    });
  });

  group('AppException', () {
    test('renders an application code and status through the framework', () {
      const e = AppException(
        code: 'drive_read_only',
        message: 'drive is read-only',
        statusCode: 403,
      );

      // The whole point: it is a HubException, so everything that maps errors to
      // the wire picks it up instead of flattening it to a 500.
      expect(e, isA<HubException>());
      expect(WsCloseCodes.forException(e), WsCloseCodes.forbidden);
    });

    test('maps unmapped statuses onto sensible close codes', () {
      expect(
        WsCloseCodes.forException(const NodeUnavailableException('gone')),
        WsCloseCodes.badGateway,
      );
      expect(
        WsCloseCodes.forException(const UnauthorizedException()),
        WsCloseCodes.unauthorized,
      );
    });
  });
}
