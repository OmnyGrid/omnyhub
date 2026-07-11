# OmnyHub node control protocol

The **data plane** (service hosting and reverse proxying) speaks ordinary
HTTP/WS(S) — there is no custom wire format there. This document describes the
**control plane**: the small JSON protocol a node and a hub exchange over a
WebSocket to register, stay alive, discover peers and answer RPCs.

## Transport

A node opens a WebSocket to the hub's node endpoint (default path `/_node`,
served by `NodeGateway`). Authentication reuses the hub's HTTP
`Authenticator`: the node presents its credentials in the WebSocket upgrade
headers (e.g. `Authorization: Bearer <token>`), so an unauthorized node is
rejected during the upgrade.

Every control message is a single WebSocket **text** frame carrying a JSON
object with a type discriminator `t`:

```json
{ "t": "<type>", ...fields }
```

`MessageCodec` performs the encode/decode and is extensible: third-party
packages may `register(type, decoder)` additional message types on top of
`MessageCodec.standard()`.

## Messages

| `t` | Direction | Purpose | Key fields |
|---|---|---|---|
| `register` | node → hub | Announce presence & capabilities | `descriptor` |
| `registered` | hub → node | Acknowledge, advertise heartbeat interval | `hubId`, `heartbeatIntervalMs` |
| `heartbeat` | node → hub | Liveness ping | `seq` |
| `heartbeat_ack` | hub → node | Acknowledge a heartbeat | `seq` |
| `query` | node → hub | Discover peers | `requestId`, `capability?`, `labels` |
| `query_result` | hub → node | Discovery result | `requestId`, `nodes[]` |
| `request` | hub → node | Invoke an action (RPC) | `requestId`, `action`, `payload` |
| `response` | node → hub | RPC result | `requestId`, `ok`, `payload`, `error?` |
| `goodbye` | node → hub | Graceful shutdown | `reason?` |
| `error` | either | Protocol error | `code`, `message`, `requestId?` |

The `descriptor` object is a `NodeDescriptor`:

```json
{
  "id": "worker-1",
  "capabilities": ["transcode", "gpu"],
  "labels": { "region": "eu" },
  "metadata": { "zone": "a" },
  "agentVersion": "1.0.0",
  "status": "online"
}
```

## Lifecycle

```
node                         hub (NodeGateway)
 |--- WS upgrade (auth) ------->|   authenticate; open control channel
 |--- register --------------->|   NodeRegistry.register(descriptor)
 |<-- registered --------------|   advertise heartbeatIntervalMs
 |--- heartbeat(seq) --------->|   recordHeartbeat; refresh lastSeen
 |<-- heartbeat_ack(seq) ------|
 |         ...                 |   HeartbeatMonitor times out silent nodes
 |--- query -> query_result -->|   discover peers
 |<-- request --- response --->|   hub-initiated RPC
 |--- goodbye ---------------->|   remove from registry, close
```

If the connection drops, the hub removes the node from its registry; the node
transitions through `backoff` and reconnects with exponential backoff
(`ReconnectPolicy`), re-registering on success. All hub-side timing is
`Clock`-driven so it is deterministic under test.

## Versioning

The protocol is intentionally small and additive: new message types are added
via the codec registry without breaking existing peers, and unknown message
types are rejected with an `error` rather than tearing the connection down.
Clustering and multi-hub federation are future extensions layered on this base.
