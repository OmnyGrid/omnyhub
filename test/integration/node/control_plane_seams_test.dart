@TestOn('vm')
library;

import 'dart:async';

import 'package:omnyhub/omnyhub_node.dart';
import 'package:test/test.dart';

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

void main() {
  late OmnyHub hub;
  late Uri nodeUri;
  final nodes = <NodeRuntime>[];

  Future<void> startHub(NodeGateway gateway) async {
    hub = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await hub.registerService(gateway);
    await hub.start();
    nodeUri = Uri.parse('ws://127.0.0.1:${hub.port}/_node');
  }

  Future<NodeRuntime> startNode(NodeConfig config) async {
    final node = NodeRuntime(config);
    nodes.add(node);
    await node.start();
    await waitFor(() => node.isReady);
    return node;
  }

  tearDown(() async {
    for (final node in nodes) {
      await node.stop();
    }
    nodes.clear();
    await hub.stop();
  });

  group('heartbeat payload', () {
    test('telemetry piggy-backed on a beat reaches the hub', () async {
      final beats = <Heartbeat>[];
      final gateway = NodeGateway(
        heartbeatInterval: const Duration(milliseconds: 50),
        onHeartbeat: (node, beat) => beats.add(beat),
      );
      await startHub(gateway);

      var sample = 0;
      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker-1'),
          heartbeatPayload: () async => {'cpu': ++sample},
        ),
      );

      await waitFor(() => beats.length >= 2);
      expect(beats.first.payload['cpu'], 1);
      expect(beats[1].payload['cpu'], 2);
      // The builder runs per beat, so the hub sees a fresh sample each time.
      expect(beats.first.seq, lessThan(beats[1].seq));
    });

    test('a throwing payload builder still lets the beat through', () async {
      // Liveness must never depend on telemetry: a broken metrics collector
      // should not make the hub believe the node is dead.
      final beats = <Heartbeat>[];
      final gateway = NodeGateway(
        heartbeatInterval: const Duration(milliseconds: 50),
        onHeartbeat: (node, beat) => beats.add(beat),
      );
      await startHub(gateway);

      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker-1'),
          heartbeatPayload: () async => throw StateError('collector down'),
        ),
      );

      await waitFor(() => beats.length >= 2);
      expect(beats.first.payload, isEmpty);
    });
  });

  group('one-way notify', () {
    test('a node pushes to the hub without a reply', () async {
      final pushed = <(String, Map<String, dynamic>)>[];
      final gateway = NodeGateway(
        onNotify: (action, payload, from) {
          expect(from.id.value, 'worker-1');
          pushed.add((action, payload));
        },
      );
      await startHub(gateway);

      final node = await startNode(
        NodeConfig(hubUri: nodeUri, nodeId: NodeId('worker-1')),
      );

      node.notify(
        'logs',
        payload: {
          'lines': ['boot ok'],
        },
      );

      await waitFor(() => pushed.isNotEmpty);
      expect(pushed.single.$1, 'logs');
      expect(pushed.single.$2['lines'], ['boot ok']);
    });

    test('the hub pushes down to a node', () async {
      final gateway = NodeGateway();
      await startHub(gateway);

      final seen = <String>[];
      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker-1'),
          onRequest: (action, payload) async {
            seen.add(action);
            return const {};
          },
        ),
      );

      expect(gateway.notify(NodeId('worker-1'), 'reload-config'), isTrue);
      await waitFor(() => seen.isNotEmpty);
      expect(seen.single, 'reload-config');
    });

    test('notifying an unknown node reports failure rather than throwing', () {
      final gateway = NodeGateway();
      expect(gateway.notify(NodeId('ghost'), 'x'), isFalse);
    });
  });

  group('connection lifecycle', () {
    test('onConnect fires for a socket that never registers', () async {
      // The registry cannot see these at all — a peer that connects and hangs up
      // without registering is invisible to registry.events.
      var connects = 0;
      RegisteredNode? disconnectedAs;
      var disconnects = 0;

      final gateway = NodeGateway(
        onConnect: (_, _) => connects++,
        onDisconnect: (node, _) {
          disconnects++;
          disconnectedAs = node;
        },
      );
      await startHub(gateway);

      final raw = await WebSocketConnection.connect(nodeUri);
      await waitFor(() => connects == 1);
      await raw.close();

      await waitFor(() => disconnects == 1);
      expect(disconnectedAs, isNull, reason: 'it never registered');
    });

    test('onDisconnect carries the registration that is going away', () async {
      final gone = Completer<RegisteredNode>();
      final gateway = NodeGateway(
        onDisconnect: (node, _) {
          if (node != null && !gone.isCompleted) gone.complete(node);
        },
      );
      await startHub(gateway);

      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker-1'),
          capabilities: {'transcode'},
        ),
      );
      await node.stop();

      final registered = await gone.future.timeout(const Duration(seconds: 5));
      // The hook gets the whole record — connection, principal and state bag —
      // not just a descriptor, so an app can audit/persist on the way out.
      expect(registered.id.value, 'worker-1');
      expect(registered.descriptor.capabilities, contains('transcode'));
    });
  });

  group('node retention', () {
    test(
      'by default a disconnected node is dropped from the registry',
      () async {
        final gateway = NodeGateway();
        await startHub(gateway);

        final node = await startNode(
          NodeConfig(hubUri: nodeUri, nodeId: NodeId('worker-1')),
        );
        await node.stop();

        await waitFor(() => gateway.registry.byId(NodeId('worker-1')) == null);
      },
    );

    test('retainNodes keeps the record, marked offline', () async {
      // The shape a fleet manager needs: the hub is the system of record, so an
      // offline node stays queryable with its last-known descriptor.
      final gateway = NodeGateway(retainNodes: true);
      await startHub(gateway);

      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker-1'),
          capabilities: {'transcode'},
        ),
      );
      await node.stop();

      await waitFor(
        () =>
            gateway.registry.byId(NodeId('worker-1'))?.descriptor.status ==
            NodeStatus.offline,
      );

      final retained = gateway.registry.byId(NodeId('worker-1'))!;
      expect(retained.descriptor.capabilities, contains('transcode'));
      // Offline nodes are still excluded from discovery.
      expect(gateway.discover(), isEmpty);
    });
  });

  group('registration race', () {
    test('frames sent during a slow onRegister are not lost', () async {
      // A node need not wait for its ack before pipelining. Before the backlog
      // fix, anything arriving while an async onRegister was in flight raced an
      // unset registration and was silently dropped.
      final gateway = NodeGateway(
        onRegister: (descriptor, payload, principal) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return const {};
        },
      );
      await startHub(gateway);

      final codec = MessageCodec.standard();
      final raw = await WebSocketConnection.connect(nodeUri);
      final replies = <NodeControlMessage>[];
      raw.incoming.listen((m) => replies.add(codec.decode(m)));

      // Register and immediately heartbeat, without waiting for the ack.
      raw.send(codec.encode(NodeRegister(NodeDescriptor(id: NodeId('eager')))));
      raw.send(codec.encode(const Heartbeat(1)));

      await waitFor(() => replies.whereType<HeartbeatAck>().isNotEmpty);

      expect(replies.whereType<NodeRegistered>(), hasLength(1));
      expect(replies.whereType<HeartbeatAck>().single.seq, 1);
      // Ordering is preserved: the ack precedes the replayed heartbeat ack.
      expect(replies.first, isA<NodeRegistered>());

      await raw.close();
    });

    test('a rejected registration discards the backlog', () async {
      final gateway = NodeGateway(
        onRegister: (descriptor, payload, principal) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          throw const UnauthorizedException('not enrolled');
        },
      );
      await startHub(gateway);

      final codec = MessageCodec.standard();
      final raw = await WebSocketConnection.connect(nodeUri);
      final replies = <NodeControlMessage>[];
      raw.incoming.listen((m) => replies.add(codec.decode(m)));

      raw.send(codec.encode(NodeRegister(NodeDescriptor(id: NodeId('bad')))));
      raw.send(codec.encode(const Heartbeat(1)));

      await waitFor(() => replies.whereType<NodeErrorMessage>().isNotEmpty);
      await raw.done;

      expect(replies.whereType<NodeErrorMessage>().single.code, 'unauthorized');
      // The queued heartbeat must not be replayed into a rejected connection.
      expect(replies.whereType<HeartbeatAck>(), isEmpty);
      expect(gateway.registry.byId(NodeId('bad')), isNull);
    });
  });

  group('malformed frames', () {
    test('a stray binary frame is answered, not fatal', () async {
      // Regression: this used to escape the gateway's listener as an uncaught
      // async error. The connection must survive and keep serving.
      final gateway = NodeGateway();
      await startHub(gateway);

      final codec = MessageCodec.standard();
      final raw = await WebSocketConnection.connect(nodeUri);
      final replies = <NodeControlMessage>[];
      raw.incoming.listen((m) => replies.add(codec.decode(m)));

      raw.send(BinaryMessage([0xC3, 0x28, 0xA0, 0xFF]));
      await waitFor(() => replies.whereType<NodeErrorMessage>().isNotEmpty);
      expect(
        replies.whereType<NodeErrorMessage>().single.code,
        'protocol_error',
      );

      // Still alive: a real registration goes through on the same connection.
      raw.send(codec.encode(NodeRegister(NodeDescriptor(id: NodeId('ok')))));
      await waitFor(() => replies.whereType<NodeRegistered>().isNotEmpty);

      await raw.close();
    });
  });
}
