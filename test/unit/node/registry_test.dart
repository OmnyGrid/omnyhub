import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/fixed_clock.dart';
import '../../support/loopback_connection.dart';

void main() {
  late NodeRegistry registry;
  late FixedClock clock;

  setUp(() {
    registry = NodeRegistry();
    clock = FixedClock(DateTime.utc(2026));
  });

  tearDown(() => registry.close());

  RegisteredNode add(
    String id, {
    Set<String> caps = const {},
    Map<String, String> labels = const {},
    String? connectionId,
  }) {
    return registry.register(
      descriptor: NodeDescriptor(
        id: NodeId(id),
        capabilities: caps,
        labels: labels,
      ),
      connection: LoopbackConnection(),
      now: clock.now(),
      connectionId: connectionId,
    );
  }

  test('register marks online and is discoverable', () {
    add('n1', caps: {'gpu'}, labels: {'region': 'eu'});
    expect(registry.length, 1);
    expect(registry.byId(NodeId('n1'))?.descriptor.status, NodeStatus.online);
    expect(registry.discover(capability: 'gpu').single.id, NodeId('n1'));
  });

  test('discovery filters by capability and labels', () {
    add('gpu-eu', caps: {'gpu'}, labels: {'region': 'eu'});
    add('gpu-us', caps: {'gpu'}, labels: {'region': 'us'});
    add('cpu-eu', caps: {'cpu'}, labels: {'region': 'eu'});

    expect(registry.discover(capability: 'gpu').map((d) => d.id.value), [
      'gpu-eu',
      'gpu-us',
    ]);
    expect(
      registry
          .discover(capability: 'gpu', labels: {'region': 'eu'})
          .single
          .id
          .value,
      'gpu-eu',
    );
    expect(registry.discover().length, 3);
  });

  test('offline nodes are excluded unless requested', () {
    add('n1');
    registry.markTimedOut(NodeId('n1'));
    expect(registry.discover(), isEmpty);
    expect(registry.discover(onlineOnly: false).single.id.value, 'n1');
  });

  test('emits events for register, timeout and remove', () async {
    final events = <NodeEventKind>[];
    registry.events.listen((e) => events.add(e.kind));
    add('n1');
    registry.markTimedOut(NodeId('n1'));
    registry.remove(NodeId('n1'));
    await Future<void>.delayed(Duration.zero);
    expect(events, [
      NodeEventKind.registered,
      NodeEventKind.timedOut,
      NodeEventKind.removed,
    ]);
  });

  test('byConnectionId and activeSessions', () {
    add('n1', connectionId: 'conn-1');
    add('n2', connectionId: 'conn-2');
    expect(registry.byConnectionId('conn-2')?.id.value, 'n2');
    expect(registry.byConnectionId('missing'), isNull);

    registry.updateActiveSessions(NodeId('n1'), 3);
    expect(registry.byId(NodeId('n1'))?.activeSessions, 3);
  });

  test('heartbeat updates lastSeen and seq', () {
    add('n1');
    clock.advance(const Duration(seconds: 5));
    registry.recordHeartbeat(id: NodeId('n1'), seq: 3, now: clock.now());
    final node = registry.byId(NodeId('n1'))!;
    expect(node.lastHeartbeatSeq, 3);
    expect(node.lastSeen, DateTime.utc(2026).add(const Duration(seconds: 5)));
  });

  group('HeartbeatMonitor', () {
    test('reports nodes past the timeout', () {
      final timedOut = <String>[];
      final monitor = HeartbeatMonitor(
        registry: registry,
        clock: clock,
        timeout: const Duration(seconds: 30),
        onTimeout: (n) => timedOut.add(n.id.value),
      );
      add('fresh');
      clock.advance(const Duration(seconds: 10));
      add('stale-later'); // registered at +10s
      clock.advance(const Duration(seconds: 25)); // now +35s

      monitor.tick();
      // 'fresh' last seen at 0, now 35 > 30 => timed out.
      // 'stale-later' last seen at 10, now 35 => 25 <= 30 => alive.
      expect(timedOut, ['fresh']);
    });
  });
}
