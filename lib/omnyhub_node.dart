/// OmnyHub node runtime — for building a *node*: a remote participant that
/// connects out to a hub, registers its capabilities, heartbeats, and
/// optionally answers RPCs.
///
/// This barrel re-exports the full core library (`package:omnyhub/omnyhub.dart`)
/// plus the node-side runtime ([NodeRuntime]/[OmnyNode], [NodeConfig],
/// [NodeState], [ReconnectPolicy]).
///
/// ```dart
/// final node = OmnyNode(NodeConfig(
///   hubUri: Uri.parse('ws://hub.local/_node'),
///   nodeId: NodeId('worker-1'),
///   capabilities: {'transcode'},
///   headers: {'authorization': 'Bearer <token>'},
/// ));
/// await node.start();
/// ```
library;

export 'omnyhub.dart';
export 'src/node/node_runtime.dart';
