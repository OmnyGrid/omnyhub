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

/// Matches on a nested catalogue held in [NodeDescriptor.attributes] — the shape
/// the flat capability/label filters cannot express.
class CatalogueMatcher implements NodeMatcher {
  @override
  bool matches(NodeDescriptor node, Map<String, dynamic> filter) {
    final wantService = filter['service'] as String?;
    final wantApi = filter['api'] as String?;
    final catalogue = node.attributes['services'];
    if (catalogue is! Map) return false;
    final apis = catalogue[wantService];
    if (apis is! List) return false;
    return wantApi == null || apis.contains(wantApi);
  }
}

/// A hub-side in-band handshake: expects `hello:<secret>`, replies `welcome`.
class SecretHandshake implements ConnectionAuthenticator {
  final String secret;
  SecretHandshake(this.secret);

  @override
  Future<Principal?> authenticate(
    HandshakeConnection connection,
    HubRequest request,
  ) async {
    final first = await connection.receive(timeout: const Duration(seconds: 5));
    final data = first is TextMessage ? first.data : '';
    if (data != 'hello:$secret') {
      throw const UnauthorizedException('bad handshake');
    }
    connection.send(const TextMessage('welcome'));
    return Principal(id: 'enrolled-node');
  }
}

void main() {
  late OmnyHub hub;
  late NodeGateway gateway;
  late Uri nodeUri;
  final nodes = <NodeRuntime>[];

  /// Builds a hub hosting [gateway] on an ephemeral port.
  Future<void> startHub(
    NodeGateway g, {
    ConnectionAuthenticator? connectionAuthenticator,
  }) async {
    gateway = g;
    hub = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
      connectionAuthenticator: connectionAuthenticator,
    );
    await hub.registerService(gateway);
    await hub.start();
    nodeUri = Uri.parse('ws://127.0.0.1:${hub.port}/_node');
  }

  Future<NodeRuntime> startNode(NodeConfig config, {bool ready = true}) async {
    final node = NodeRuntime(config);
    nodes.add(node);
    await node.start();
    if (ready) {
      await node.states.firstWhere((s) => s == NodeState.ready);
    }
    return node;
  }

  tearDown(() async {
    for (final node in nodes) {
      await node.stop();
    }
    nodes.clear();
    await hub.stop();
  });

  group('node → hub RPC', () {
    test('a node calls an action on the hub and gets the response', () async {
      await startHub(
        NodeGateway(
          onRequest: (action, payload, from) async => {
            'echo': action,
            'got': payload['value'],
            'caller': from.id.value,
          },
        ),
      );
      final node = await startNode(
        NodeConfig(hubUri: nodeUri, nodeId: NodeId('caller')),
      );

      final response = await node.request('enrol', payload: {'value': 42});

      expect(response.ok, isTrue);
      expect(response.payload['echo'], 'enrol');
      expect(response.payload['got'], 42);
      // The hub knows which node called it.
      expect(response.payload['caller'], 'caller');
    });

    test('the hub rejects requests when it serves no actions', () async {
      await startHub(NodeGateway());
      final node = await startNode(
        NodeConfig(hubUri: nodeUri, nodeId: NodeId('caller')),
      );

      final response = await node.request('enrol');

      expect(response.ok, isFalse);
      expect(response.error, 'No request handler');
    });

    test('an unregistered caller is turned away', () async {
      var handlerRan = false;
      await startHub(
        NodeGateway(
          onRequest: (action, payload, from) async {
            handlerRan = true;
            return {};
          },
        ),
      );

      // A raw control connection that skips registration entirely.
      final codec = MessageCodec.standard();
      final connection = await WebSocketConnection.connect(nodeUri);
      final reply = connection.incoming.map(codec.decode).first;
      connection.send(codec.encode(const NodeRequest('r1', 'enrol')));

      final response = await reply as NodeResponse;
      expect(response.ok, isFalse);
      expect(response.error, 'Not registered');
      // Rejected before the application ever saw it.
      expect(handlerRan, isFalse);

      await connection.close();
    });

    test('a throwing hub handler yields a failed response', () async {
      await startHub(
        NodeGateway(
          onRequest: (action, payload, from) async =>
              throw const ValidationException('bad csr'),
        ),
      );
      final node = await startNode(
        NodeConfig(hubUri: nodeUri, nodeId: NodeId('caller')),
      );

      final response = await node.request('enrol');

      expect(response.ok, isFalse);
      expect(response.error, contains('bad csr'));
    });

    test('a hub that never answers times out', () async {
      await startHub(
        NodeGateway(
          onRequest: (action, payload, from) =>
              Completer<Map<String, dynamic>>().future, // never completes
        ),
      );
      final node = await startNode(
        NodeConfig(hubUri: nodeUri, nodeId: NodeId('caller')),
      );

      await expectLater(
        node.request('slow', timeout: const Duration(milliseconds: 200)),
        throwsA(isA<HubTimeoutException>()),
      );
    });

    test('an in-flight request fails when the connection drops', () async {
      await startHub(
        NodeGateway(
          onRequest: (action, payload, from) =>
              Completer<Map<String, dynamic>>().future,
        ),
      );
      final node = await startNode(
        NodeConfig(hubUri: nodeUri, nodeId: NodeId('caller')),
      );

      final pending = node.request(
        'slow',
        timeout: const Duration(seconds: 30),
      );
      // Drop the control connection from the hub side while the call is open.
      await gateway.registry.byId(NodeId('caller'))!.connection.close();

      // Fails promptly with NodeUnavailable rather than hanging for 30s.
      await expectLater(pending, throwsA(isA<NodeUnavailableException>()));
    });

    test('hub → node RPC still works (unchanged direction)', () async {
      await startHub(NodeGateway());
      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker'),
          onRequest: (action, payload) async => {'did': action},
        ),
      );

      final response = await gateway.request(NodeId('worker'), 'encode');

      expect(response.ok, isTrue);
      expect(response.payload['did'], 'encode');
    });
  });

  group('registration', () {
    test('carries a payload up and an ack payload back', () async {
      Map<String, dynamic>? seen;
      await startHub(
        NodeGateway(
          onRegister: (descriptor, payload, principal) async {
            seen = payload;
            return {'certificate': 'signed(${payload['csr']})'};
          },
        ),
      );

      NodeRegistered? acked;
      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('enrolling'),
          registerPayload: () async => {'csr': 'CSR-1'},
          onRegistered: (ack) async => acked = ack,
        ),
      );

      // The hub saw the node's CSR...
      expect(seen, {'csr': 'CSR-1'});
      // ...and the node got its signed certificate back.
      expect(node.registration!.payload['certificate'], 'signed(CSR-1)');
      expect(acked!.payload['certificate'], 'signed(CSR-1)');
    });

    test('a rejecting hub keeps the node out of the registry', () async {
      await startHub(
        NodeGateway(
          onRegister: (descriptor, payload, principal) async =>
              throw const UnauthorizedException('unknown node'),
        ),
      );

      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('impostor'),
          registerTimeout: const Duration(milliseconds: 300),
        ),
        ready: false,
      );

      // It never becomes ready, and the hub never registered it.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(node.isReady, isFalse);
      expect(gateway.registry.byId(NodeId('impostor')), isNull);
      expect(gateway.nodes, isEmpty);
    });

    test('descriptor attributes reach the hub', () async {
      await startHub(NodeGateway());
      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('rich'),
          attributes: {
            'org': 'acme',
            'services': {
              'auth': ['login', 'logout'],
            },
          },
        ),
      );

      final descriptor = gateway.registry.byId(NodeId('rich'))!.descriptor;
      expect(descriptor.attributes['org'], 'acme');
      expect(descriptor.attributes['services'], {
        'auth': ['login', 'logout'],
      });
    });
  });

  group('discovery', () {
    test('a NodeMatcher interprets an application filter', () async {
      await startHub(NodeGateway(matcher: CatalogueMatcher()));

      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('auth-node'),
          attributes: {
            'services': {
              'auth': ['login'],
            },
          },
        ),
      );
      await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('billing-node'),
          attributes: {
            'services': {
              'billing': ['invoice'],
            },
          },
        ),
      );

      final peers =
          await startNode(
            NodeConfig(hubUri: nodeUri, nodeId: NodeId('client-node')),
          ).then(
            (n) => n.discoverPeers(filter: {'service': 'auth', 'api': 'login'}),
          );

      expect(peers.map((p) => p.id.value), ['auth-node']);
    });

    test('an unmatched filter finds nothing', () async {
      await startHub(NodeGateway(matcher: CatalogueMatcher()));
      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('auth-node'),
          attributes: {
            'services': {
              'auth': ['login'],
            },
          },
        ),
      );

      final peers = await node.discoverPeers(filter: {'service': 'nope'});

      expect(peers, isEmpty);
    });

    test('capability discovery is unaffected by the filter field', () async {
      await startHub(NodeGateway(matcher: CatalogueMatcher()));
      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker'),
          capabilities: {'transcode'},
        ),
      );

      expect(
        (await node.discoverPeers(
          capability: 'transcode',
        )).map((p) => p.id.value),
        ['worker'],
      );
    });
  });

  group('descriptor updates', () {
    test('a node revises what it advertises without re-registering', () async {
      await startHub(NodeGateway());
      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('worker'),
          capabilities: {'transcode'},
        ),
      );

      expect(gateway.discover(capability: 'gpu'), isEmpty);

      node.updateDescriptor(
        NodeDescriptor(
          id: NodeId('worker'),
          capabilities: {'transcode', 'gpu'},
          attributes: {'lane': 'fast'},
        ),
      );

      await waitFor(() => gateway.discover(capability: 'gpu').isNotEmpty);
      final descriptor = gateway.registry.byId(NodeId('worker'))!.descriptor;
      expect(descriptor.attributes['lane'], 'fast');
      // Still online — the update did not disturb liveness.
      expect(descriptor.status, NodeStatus.online);
    });
  });

  group('in-band handshake', () {
    test('a node completes the hub handshake, then registers', () async {
      await startHub(
        NodeGateway(),
        connectionAuthenticator: SecretHandshake('s3cret'),
      );

      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('handshaker'),
          onHandshake: (connection) async {
            connection.send(const TextMessage('hello:s3cret'));
            final reply = await connection.receive(
              timeout: const Duration(seconds: 5),
            );
            if (reply is! TextMessage || reply.data != 'welcome') {
              throw const UnauthorizedException('hub refused');
            }
          },
        ),
      );

      // Registration rode the same connection, after the handshake.
      expect(node.isReady, isTrue);
      final registered = gateway.registry.byId(NodeId('handshaker'))!;
      // The principal established in-band is attached to the node.
      expect(registered.principal?.id, 'enrolled-node');
    });

    test('a failed handshake keeps the node from registering', () async {
      await startHub(
        NodeGateway(),
        connectionAuthenticator: SecretHandshake('s3cret'),
      );

      final node = await startNode(
        NodeConfig(
          hubUri: nodeUri,
          nodeId: NodeId('wrong'),
          registerTimeout: const Duration(milliseconds: 300),
          onHandshake: (connection) async {
            connection.send(const TextMessage('hello:wrong'));
            await connection.receive(
              timeout: const Duration(milliseconds: 300),
            );
          },
        ),
        ready: false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(node.isReady, isFalse);
      expect(gateway.registry.byId(NodeId('wrong')), isNull);
    });
  });
}
