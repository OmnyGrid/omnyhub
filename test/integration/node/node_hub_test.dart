@TestOn('vm')
library;

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
  late NodeGateway gateway;
  late Uri nodeUri;
  final nodes = <NodeRuntime>[];

  setUp(() async {
    hub = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    gateway = NodeGateway(
      heartbeatInterval: const Duration(milliseconds: 100),
      heartbeatTimeout: const Duration(milliseconds: 800),
    );
    await hub.registerService(gateway);
    await hub.start();
    nodeUri = Uri.parse('ws://127.0.0.1:${hub.port}/_node');
  });

  tearDown(() async {
    for (final node in nodes) {
      await node.stop();
    }
    nodes.clear();
    await hub.stop();
  });

  NodeRuntime spawn(
    String id, {
    Set<String> capabilities = const {},
    Map<String, String> labels = const {},
    NodeActionHandler? onRequest,
    ReconnectPolicy? reconnect,
  }) {
    final node = NodeRuntime(
      NodeConfig(
        hubUri: nodeUri,
        nodeId: NodeId(id),
        capabilities: capabilities,
        labels: labels,
        onRequest: onRequest,
        reconnect: reconnect,
      ),
    );
    nodes.add(node);
    return node;
  }

  test(
    'a node registers, is discoverable, and stays alive via heartbeats',
    () async {
      final node = spawn('worker-1', capabilities: {'transcode'});
      await node.start();
      await waitFor(() => node.isReady);

      expect(
        gateway.discover(capability: 'transcode').single.id.value,
        'worker-1',
      );

      // Survive several heartbeat intervals without being timed out.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(gateway.discover(capability: 'transcode'), isNotEmpty);

      await node.stop();
      await waitFor(() => gateway.nodes.isEmpty);
    },
  );

  test('hub invokes an RPC on a node', () async {
    final node = spawn(
      'rpc-node',
      onRequest: (action, payload) async {
        if (action == 'echo') return {'echo': payload['msg']};
        throw StateError('unknown action');
      },
    );
    await node.start();
    await waitFor(() => node.isReady);

    final ok = await gateway.request(
      NodeId('rpc-node'),
      'echo',
      payload: {'msg': 'hi'},
    );
    expect(ok.ok, isTrue);
    expect(ok.payload['echo'], 'hi');

    final fail = await gateway.request(NodeId('rpc-node'), 'nope');
    expect(fail.ok, isFalse);

    expect(
      () => gateway.request(NodeId('ghost'), 'x'),
      throwsA(isA<NodeUnavailableException>()),
    );
  });

  test('a node discovers its peers through the hub', () async {
    final a = spawn('worker-a', capabilities: {'gpu'});
    final b = spawn(
      'worker-b',
      capabilities: {'cpu'},
      labels: {'region': 'eu'},
    );
    await a.start();
    await b.start();
    await waitFor(() => a.isReady && b.isReady);
    await waitFor(() => gateway.nodes.length == 2);

    final cpuPeers = await a.discoverPeers(capability: 'cpu');
    expect(cpuPeers.single.id.value, 'worker-b');

    final euPeers = await a.discoverPeers(labels: {'region': 'eu'});
    expect(euPeers.single.id.value, 'worker-b');

    expect((await a.discoverPeers()).length, 2);
  });

  test(
    'a node reconnects and re-registers after its connection drops',
    () async {
      final node = spawn(
        'resilient',
        capabilities: {'x'},
        reconnect: ReconnectPolicy(initial: const Duration(milliseconds: 100)),
      );
      await node.start();
      await waitFor(() => node.isReady);

      // Drop the server-side connection to simulate a network blip.
      final registered = gateway.registry.byId(NodeId('resilient'))!;
      await registered.connection.close();

      // The node detects the drop, backs off, reconnects and re-registers.
      await waitFor(
        () => node.state == NodeState.ready && gateway.nodes.isNotEmpty,
        timeout: const Duration(seconds: 8),
      );
      expect(gateway.discover(capability: 'x').single.id.value, 'resilient');
    },
  );
}
