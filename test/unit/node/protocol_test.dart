import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('NodeDescriptor', () {
    test('round-trips through JSON', () {
      final d = NodeDescriptor(
        id: NodeId('worker-1'),
        capabilities: {'gpu', 'transcode'},
        labels: {'region': 'eu'},
        metadata: {'zone': 'a'},
        agentVersion: '1.2.3',
        status: NodeStatus.online,
      );
      final restored = NodeDescriptor.fromJson(d.toJson());
      expect(restored.id, d.id);
      expect(restored.capabilities, d.capabilities);
      expect(restored.labels, d.labels);
      expect(restored.status, NodeStatus.online);
    });

    test('capability and label matching', () {
      final d = NodeDescriptor(
        id: NodeId('n'),
        capabilities: {'gpu'},
        labels: {'region': 'eu', 'tier': 'hot'},
      );
      expect(d.hasCapability('gpu'), isTrue);
      expect(d.hasCapability('cpu'), isFalse);
      expect(d.matchesLabels({'region': 'eu'}), isTrue);
      expect(d.matchesLabels({'region': 'us'}), isFalse);
    });
  });

  group('NodeId', () {
    test('rejects invalid ids', () {
      expect(() => NodeId(''), throwsA(isA<ValidationException>()));
      expect(() => NodeId('bad id'), throwsA(isA<ValidationException>()));
      expect(NodeId('ok-1.2_3').value, 'ok-1.2_3');
    });
  });

  group('MessageCodec', () {
    final codec = MessageCodec.standard();

    test('encodes and decodes each control message', () {
      final messages = <NodeControlMessage>[
        NodeRegister(NodeDescriptor(id: NodeId('n'), capabilities: {'x'})),
        const NodeRegistered('hub-1', 5000),
        const Heartbeat(7),
        const HeartbeatAck(7),
        const NodeQuery('q1', capability: 'gpu', labels: {'r': 'eu'}),
        NodeQueryResult('q1', [NodeDescriptor(id: NodeId('n'))]),
        const NodeRequest('r1', 'ping', payload: {'a': 1}),
        const NodeResponse('r1', payload: {'b': 2}),
        NodeResponse.failure('r1', 'boom'),
        const NodeGoodbye('bye'),
        const NodeErrorMessage('code', 'msg', requestId: 'r1'),
      ];
      for (final m in messages) {
        final decoded = codec.decode(codec.encode(m));
        expect(decoded.runtimeType, m.runtimeType);
        expect(decoded.type, m.type);
      }
    });

    test('rejects malformed and unknown messages', () {
      expect(
        () => codec.decode(const TextMessage('not json')),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => codec.decode(const TextMessage('{"t":"nope"}')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('supports registering custom message types', () {
      final custom = MessageCodec.standard()
        ..register('heartbeat', Heartbeat.fromJson);
      expect(
        custom.decode(const TextMessage('{"t":"heartbeat","seq":9}')),
        isA<Heartbeat>(),
      );
    });
  });
}
