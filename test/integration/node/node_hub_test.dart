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

  group('a rejected registration', () {
    late OmnyHub rejectingHub;
    late Uri rejectingUri;

    setUp(() async {
      rejectingHub = OmnyHub(
        transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      );
      await rejectingHub.registerService(
        NodeGateway(
          onRegister: (descriptor, payload, principal) async =>
              throw ForbiddenException(
                'principal may not register node ${descriptor.id.value}',
              ),
        ),
      );
      await rejectingHub.start();
      rejectingUri = Uri.parse('ws://127.0.0.1:${rejectingHub.port}/_node');
    });

    tearDown(() => rejectingHub.stop());

    // The register future used to be left pending on a rejection, so the node
    // waited out registerTimeout (10s) before even backing off. The long timeout
    // here proves it no longer does: a rejection arrives as a typed error at once.
    test(
      'fails with the typed error, without waiting out the timeout',
      () async {
        final node = NodeRuntime(
          NodeConfig(
            hubUri: rejectingUri,
            nodeId: NodeId('rejected'),
            registerTimeout: const Duration(seconds: 30),
            reconnect: ReconnectPolicy(
              initial: const Duration(milliseconds: 50),
            ),
            isTerminal: (e) => e is ForbiddenException,
          ),
        );
        nodes.add(node);

        final stopwatch = Stopwatch()..start();
        await node.start();
        await waitFor(
          () => node.state == NodeState.stopped,
          timeout: const Duration(seconds: 5),
        );
        stopwatch.stop();

        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason:
              'the rejection is delivered at once, not after registerTimeout',
        );
        expect(node.terminalError, isA<ForbiddenException>());
        expect(
          (node.terminalError! as ForbiddenException).message,
          allOf(contains('may not register'), contains('rejected')),
        );
      },
    );

    // When the node does not treat the rejection as terminal, it keeps trying —
    // and, crucially, tries *again quickly* rather than once every timeout.
    test('retries promptly when not classified terminal', () async {
      var attempts = 0;
      final node = NodeRuntime(
        NodeConfig(
          hubUri: rejectingUri,
          nodeId: NodeId('persistent'),
          registerTimeout: const Duration(seconds: 30),
          reconnect: ReconnectPolicy(initial: const Duration(milliseconds: 50)),
        ),
      );
      nodes.add(node);
      node.states.listen((s) {
        if (s == NodeState.backoff) attempts++;
      });

      await node.start();
      // Several attempts inside a window far shorter than one registerTimeout
      // proves the register no longer blocks for 30s per try.
      await waitFor(() => attempts >= 3, timeout: const Duration(seconds: 5));
      expect(node.state, isNot(NodeState.stopped));
    });
  });
}
