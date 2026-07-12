@TestOn('vm')
library;

import 'dart:async';

import 'package:omnyhub/omnyhub_node.dart';
import 'package:test/test.dart';

import '../../support/loopback_connection.dart';

/// Polls [condition] until true or a timeout elapses.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!condition()) throw StateError('condition not met within $timeout');
}

/// The hub half of a loopback control channel: acks whatever registers.
///
/// Stands in for a whole `OmnyHub` + `NodeGateway` + socket, which is the point
/// of [NodeConfig.connect] — the runtime is drivable without a listener.
class FakeHub {
  final LoopbackConnection connection;
  final MessageCodec codec = MessageCodec.standard();
  final List<NodeControlMessage> received = [];

  FakeHub(this.connection) {
    connection.incoming.listen((message) {
      final decoded = codec.decode(message);
      received.add(decoded);
      if (decoded is NodeRegister) {
        connection.send(codec.encode(const NodeRegistered('hub-1', 60000)));
      }
    });
  }
}

void main() {
  group('NodeConfig.connect', () {
    test(
      'drives a runtime over a loopback connection, with no socket',
      () async {
        final (nodeSide, hubSide) = LoopbackConnection.pair();
        final fakeHub = FakeHub(hubSide);

        final node = NodeRuntime(
          NodeConfig(
            hubUri: Uri.parse('ws://unused/'),
            nodeId: NodeId('worker-1'),
            capabilities: {'transcode'},
            connect: () async => nodeSide,
          ),
        );
        addTearDown(node.stop);

        await node.start();
        await waitFor(() => node.isReady);

        expect(node.registration?.hubId, 'hub-1');
        final register = fakeHub.received.whereType<NodeRegister>().single;
        expect(register.descriptor.id.value, 'worker-1');
        expect(register.descriptor.capabilities, contains('transcode'));
      },
    );

    test('a one-way notify rides the injected connection', () async {
      final (nodeSide, hubSide) = LoopbackConnection.pair();
      final fakeHub = FakeHub(hubSide);

      final node = NodeRuntime(
        NodeConfig(
          hubUri: Uri.parse('ws://unused/'),
          nodeId: NodeId('worker-1'),
          connect: () async => nodeSide,
        ),
      );
      addTearDown(node.stop);

      await node.start();
      await waitFor(() => node.isReady);

      node.notify('status', payload: {'healthy': true});

      await waitFor(() => fakeHub.received.whereType<NodeNotify>().isNotEmpty);
      final notify = fakeHub.received.whereType<NodeNotify>().single;
      expect(notify.action, 'status');
      expect(notify.payload['healthy'], true);
    });

    test('a notify before the node is ready is dropped, not queued', () async {
      final (nodeSide, hubSide) = LoopbackConnection.pair();
      final fakeHub = FakeHub(hubSide);

      final node = NodeRuntime(
        NodeConfig(
          hubUri: Uri.parse('ws://unused/'),
          nodeId: NodeId('worker-1'),
          connect: () async => nodeSide,
        ),
      );
      addTearDown(node.stop);

      // Best-effort by contract: nothing to send it over yet.
      node.notify('early');
      expect(fakeHub.received, isEmpty);

      await node.start();
      await waitFor(() => node.isReady);
      expect(fakeHub.received.whereType<NodeNotify>(), isEmpty);
    });
  });

  group('NodeConfig.isTerminal', () {
    test(
      'an unrecoverable failure stops the runtime instead of retrying',
      () async {
        // A revoked key is not fixed by reconnecting; without this the node would
        // back off and hammer the hub forever.
        var attempts = 0;
        final node = NodeRuntime(
          NodeConfig(
            hubUri: Uri.parse('ws://unused/'),
            nodeId: NodeId('worker-1'),
            connect: () async {
              attempts++;
              throw const UnauthorizedException('key revoked');
            },
            isTerminal: (error) => error is UnauthorizedException,
            reconnect: ReconnectPolicy(
              initial: const Duration(milliseconds: 10),
            ),
          ),
        );
        addTearDown(node.stop);

        await node.start();
        await waitFor(() => node.state == NodeState.stopped);

        expect(attempts, 1, reason: 'it must not retry a terminal failure');
        expect(node.terminalError, isA<UnauthorizedException>());
      },
    );

    test('a recoverable failure still retries with backoff', () async {
      var attempts = 0;
      final (nodeSide, hubSide) = LoopbackConnection.pair();
      FakeHub(hubSide);

      final node = NodeRuntime(
        NodeConfig(
          hubUri: Uri.parse('ws://unused/'),
          nodeId: NodeId('worker-1'),
          connect: () async {
            // Fail once (the hub was restarting), then succeed.
            if (++attempts == 1) throw const TransportException('refused');
            return nodeSide;
          },
          isTerminal: (error) => error is UnauthorizedException,
          reconnect: ReconnectPolicy(initial: const Duration(milliseconds: 10)),
        ),
      );
      addTearDown(node.stop);

      await node.start();
      await waitFor(() => node.isReady);

      expect(attempts, 2);
      expect(node.terminalError, isNull);
    });

    test('by default every failure is retried', () async {
      var attempts = 0;
      final node = NodeRuntime(
        NodeConfig(
          hubUri: Uri.parse('ws://unused/'),
          nodeId: NodeId('worker-1'),
          connect: () async {
            attempts++;
            throw const UnauthorizedException('key revoked');
          },
          reconnect: ReconnectPolicy(initial: const Duration(milliseconds: 10)),
        ),
      );
      addTearDown(node.stop);

      await node.start();
      await waitFor(() => attempts >= 3);

      // Unchanged 1.2.0 behaviour: no isTerminal means keep trying.
      expect(node.terminalError, isNull);
      expect(node.state, isNot(NodeState.stopped));
    });
  });

  group('RegisteredNode.state', () {
    test('carries application-owned per-node state', () {
      // The registry constructs RegisteredNode itself, so subclassing it to add
      // fields does not work — this bag is the seam.
      final registry = NodeRegistry();
      addTearDown(registry.close);

      final node = registry.register(
        descriptor: NodeDescriptor(id: NodeId('worker-1')),
        connection: LoopbackConnection(),
        now: DateTime.utc(2026),
      );

      node.state['lastStatus'] = {'cpu': 0.5};
      expect(registry.byId(NodeId('worker-1'))!.state['lastStatus'], {
        'cpu': 0.5,
      });
    });
  });

  group('NodeEvent.node', () {
    test('events carry the registration, not just the descriptor', () async {
      final registry = NodeRegistry();
      addTearDown(registry.close);

      final events = <NodeEvent>[];
      registry.events.listen(events.add);

      final connection = LoopbackConnection();
      registry.register(
        descriptor: NodeDescriptor(id: NodeId('worker-1')),
        connection: connection,
        now: DateTime.utc(2026),
        principal: Principal(id: 'svc'),
      );

      await waitFor(() => events.isNotEmpty);
      final event = events.single;
      expect(event.kind, NodeEventKind.registered);
      // Previously a subscriber had to re-look-up the registry to reach these.
      expect(event.node?.connection, same(connection));
      expect(event.node?.principal?.id, 'svc');
    });

    test(
      'markOffline retains the node and reports it as disconnected',
      () async {
        final registry = NodeRegistry();
        addTearDown(registry.close);

        final events = <NodeEvent>[];
        registry.events.listen(events.add);

        registry.register(
          descriptor: NodeDescriptor(id: NodeId('worker-1')),
          connection: LoopbackConnection(),
          now: DateTime.utc(2026),
        );
        registry.markOffline(NodeId('worker-1'));

        await waitFor(() => events.length >= 2);
        expect(events.last.kind, NodeEventKind.disconnected);
        expect(registry.byId(NodeId('worker-1')), isNotNull);
        expect(registry.discover(), isEmpty);
      },
    );
  });
}
