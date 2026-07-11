import 'dart:io';

import 'package:omnyhub/omnyhub_node.dart';

/// Resolves a committed test certificate fixture path.
String certPath(String name) => 'test/support/certs/$name';

/// A [StaticTls] built from the committed self-signed `localhost` fixtures.
StaticTls localhostTls() =>
    StaticTls.files(certPath('localhost.crt'), certPath('localhost.key'));

/// Accepts the self-signed test certificate (for clients in tests only).
bool acceptTestCert(X509Certificate cert, String host, int port) => true;

/// A small end-to-end cluster: a hub serving HTTP + HTTPS on loopback with a
/// multi-service surface, a reverse proxy to a real backend, and a node
/// gateway. Spins everything up on ephemeral ports and tears it down with
/// [dispose].
class TestCluster {
  /// The gateway hub (HTTP + HTTPS).
  final OmnyHub hub;

  /// The backend hub the gateway proxies to.
  final OmnyHub backend;

  /// The node gateway hosted on [hub].
  final NodeGateway gateway;

  /// The plaintext port of [hub].
  final int httpPort;

  /// The TLS port of [hub].
  final int httpsPort;

  final List<NodeRuntime> _nodes = [];

  TestCluster._({
    required this.hub,
    required this.backend,
    required this.gateway,
    required this.httpPort,
    required this.httpsPort,
  });

  /// Starts the cluster.
  static Future<TestCluster> start() async {
    // Backend that the gateway reverse-proxies to (HTTP + WS echo).
    final backend = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await backend.registerService(
      HandlerService(
        name: 'backend',
        handler: (r) async =>
            HubResponse.json({'from': 'backend', 'path': r.path}),
        onConnection: (conn, _) {
          conn.incoming.listen((m) {
            if (m is TextMessage) conn.send(TextMessage('backend:${m.data}'));
          });
        },
      ),
    );
    await backend.start();
    final backendBase = 'http://127.0.0.1:${backend.port}';

    final gateway = NodeGateway(
      heartbeatInterval: const Duration(milliseconds: 100),
      heartbeatTimeout: const Duration(seconds: 2),
    );

    final hub = OmnyHub(
      transports: [
        HttpTransport.http(address: '127.0.0.1', port: 0),
        HttpTransport.https(address: '127.0.0.1', port: 0, tls: localhostTls()),
      ],
      authenticator: BearerTokenAuthenticator({
        'node-token': Principal(id: 'node', roles: {'node'}),
      }),
    );
    await hub.registerService(
      HandlerService(
        name: 'api',
        mount: '/api',
        handler: (r) async => HubResponse.json({'service': 'api'}),
      ),
    );
    await hub.registerService(gateway);
    await hub.route(
      PathRule('/proxy'),
      ProxyService(Upstream.uri(backendBase), name: 'proxy', mount: '/proxy'),
    );
    await hub.start();

    return TestCluster._(
      hub: hub,
      backend: backend,
      gateway: gateway,
      httpPort: hub.transports[0].port,
      httpsPort: hub.transports[1].port,
    );
  }

  /// The `ws://` node control URL.
  Uri get nodeControlUri => Uri.parse('ws://127.0.0.1:$httpPort/_node');

  /// Starts a node connected to this cluster's gateway.
  Future<NodeRuntime> startNode(
    String id, {
    Set<String> capabilities = const {},
    NodeActionHandler? onRequest,
  }) async {
    final node = NodeRuntime(
      NodeConfig(
        hubUri: nodeControlUri,
        nodeId: NodeId(id),
        capabilities: capabilities,
        headers: {'authorization': 'Bearer node-token'},
        onRequest: onRequest,
      ),
    );
    _nodes.add(node);
    await node.start();
    return node;
  }

  /// Stops the cluster and everything in it.
  Future<void> dispose() async {
    for (final node in _nodes) {
      await node.stop();
    }
    await hub.stop();
    await backend.stop();
  }
}
