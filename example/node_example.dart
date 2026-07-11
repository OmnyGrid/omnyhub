// Runs a hub with a node gateway and connects a worker node that registers,
// heartbeats, is discovered, and answers an RPC — all over loopback WebSockets.
//
// Run with: dart run example/node_example.dart
import 'package:omnyhub/omnyhub_node.dart';

Future<void> main() async {
  // Hub hosting the node control endpoint at /_node.
  final hub = OmnyHub(
    transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
  );
  final gateway = NodeGateway();
  await hub.registerService(gateway);
  await hub.start();
  print('Hub node endpoint: ws://127.0.0.1:${hub.port}/_node');

  // A worker node that advertises a capability and serves an RPC.
  final node = OmnyNode(
    NodeConfig(
      hubUri: Uri.parse('ws://127.0.0.1:${hub.port}/_node'),
      nodeId: NodeId('worker-1'),
      capabilities: {'transcode'},
      labels: {'region': 'local'},
      onRequest: (action, payload) async => {
        'result': '$action:${payload['job']}',
      },
    ),
  );
  await node.start();

  // Wait for the node to register.
  await node.states.firstWhere((s) => s == NodeState.ready);
  print(
    'Node ready; hub sees: '
    '${gateway.discover(capability: 'transcode').map((d) => d.id.value).toList()}',
  );

  // Invoke an RPC on the node through the hub.
  final response = await gateway.request(
    NodeId('worker-1'),
    'encode',
    payload: {'job': 'clip.mp4'},
  );
  print('RPC result: ${response.payload['result']}');

  await node.stop();
  await hub.stop();
}
