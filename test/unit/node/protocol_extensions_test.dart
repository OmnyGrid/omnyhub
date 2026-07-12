@TestOn('vm')
library;

import 'dart:convert';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// Round-trips [message] through the standard codec.
NodeControlMessage roundTrip(NodeControlMessage message) {
  final codec = MessageCodec.standard();
  return codec.decode(codec.encode(message));
}

/// The JSON body a message encodes to (without the `t` discriminator).
Map<String, dynamic> wire(NodeControlMessage message) {
  final encoded = MessageCodec.standard().encode(message) as TextMessage;
  return jsonDecode(encoded.data) as Map<String, dynamic>;
}

void main() {
  group('NodeDescriptor.attributes', () {
    test('round-trips nested JSON values', () {
      final descriptor = NodeDescriptor(
        id: NodeId('n1'),
        attributes: {
          'org': 'acme',
          'services': {
            'auth': ['login', 'logout'],
          },
          'weight': 7,
        },
      );

      final decoded = NodeDescriptor.fromJson(descriptor.toJson());

      expect(decoded.attributes['org'], 'acme');
      expect(decoded.attributes['services'], {
        'auth': ['login', 'logout'],
      });
      expect(decoded.attributes['weight'], 7);
    });

    test('is omitted from the wire when empty, so old peers see no change', () {
      final json = NodeDescriptor(id: NodeId('n1')).toJson();

      expect(json.containsKey('attributes'), isFalse);
      expect(NodeDescriptor.fromJson(json).attributes, isEmpty);
    });

    test('survives copyWith', () {
      final descriptor = NodeDescriptor(
        id: NodeId('n1'),
        attributes: {'org': 'acme'},
      );

      expect(descriptor.copyWith(status: NodeStatus.online).attributes, {
        'org': 'acme',
      });
      expect(descriptor.copyWith(attributes: {'org': 'other'}).attributes, {
        'org': 'other',
      });
    });
  });

  group('NodeRegister / NodeRegistered payloads', () {
    test('carry arbitrary JSON in both directions', () {
      final register =
          roundTrip(
                NodeRegister(
                  NodeDescriptor(id: NodeId('n1')),
                  payload: {
                    'csr': 'CSR-1',
                    'chain': ['a', 'b'],
                  },
                ),
              )
              as NodeRegister;
      expect(register.payload['csr'], 'CSR-1');
      expect(register.payload['chain'], ['a', 'b']);

      final registered =
          roundTrip(
                const NodeRegistered(
                  'hub-1',
                  5000,
                  payload: {'certificate': 'signed'},
                ),
              )
              as NodeRegistered;
      expect(registered.hubId, 'hub-1');
      expect(registered.heartbeatIntervalMs, 5000);
      expect(registered.payload['certificate'], 'signed');
    });

    test('omit the payload on the wire when empty', () {
      expect(
        wire(
          NodeRegister(NodeDescriptor(id: NodeId('n1'))),
        ).containsKey('payload'),
        isFalse,
      );
      expect(
        wire(const NodeRegistered('hub-1', 1000)).containsKey('payload'),
        isFalse,
      );
    });

    test('decode with no payload field yields an empty payload', () {
      final decoded =
          MessageCodec.standard().decode(
                TextMessage(
                  jsonEncode({
                    't': 'registered',
                    'hubId': 'hub-1',
                    'heartbeatIntervalMs': 1000,
                  }),
                ),
              )
              as NodeRegistered;

      expect(decoded.payload, isEmpty);
    });
  });

  group('NodeQuery.filter', () {
    test('round-trips alongside capability and labels', () {
      final decoded =
          roundTrip(
                const NodeQuery(
                  'q1',
                  capability: 'transcode',
                  labels: {'region': 'eu'},
                  filter: {'service': 'auth', 'minVersion': 2},
                ),
              )
              as NodeQuery;

      expect(decoded.requestId, 'q1');
      expect(decoded.capability, 'transcode');
      expect(decoded.labels, {'region': 'eu'});
      expect(decoded.filter, {'service': 'auth', 'minVersion': 2});
    });

    test('is omitted from the wire when empty', () {
      expect(wire(const NodeQuery('q1')).containsKey('filter'), isFalse);
    });
  });

  group('NodeUpdate', () {
    test('round-trips its descriptor', () {
      final decoded =
          roundTrip(
                NodeUpdate(
                  NodeDescriptor(
                    id: NodeId('n1'),
                    capabilities: {'gpu'},
                    attributes: {'lane': 'fast'},
                  ),
                ),
              )
              as NodeUpdate;

      expect(decoded.descriptor.id.value, 'n1');
      expect(decoded.descriptor.capabilities, {'gpu'});
      expect(decoded.descriptor.attributes['lane'], 'fast');
    });

    test('is registered in the standard codec under "update"', () {
      expect(wire(NodeUpdate(NodeDescriptor(id: NodeId('n1'))))['t'], 'update');
    });
  });

  group('Json.optObject', () {
    test('returns an empty map when the field is absent', () {
      expect(Json.optObject(const {}, 'payload'), isEmpty);
    });

    test('rejects a non-object field', () {
      expect(
        () => Json.optObject(const {'payload': 'nope'}, 'payload'),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
