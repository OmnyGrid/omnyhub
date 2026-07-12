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
| `register` | node → hub | Announce presence & capabilities | `descriptor`, `payload?` |
| `registered` | hub → node | Acknowledge, advertise heartbeat interval | `hubId`, `heartbeatIntervalMs`, `payload?` |
| `update` | node → hub | Revise the advertised descriptor | `descriptor` |
| `heartbeat` | node → hub | Liveness ping, optionally carrying telemetry | `seq`, `payload?` |
| `heartbeat_ack` | hub → node | Acknowledge a heartbeat | `seq` |
| `query` | node → hub | Discover peers | `requestId`, `capability?`, `labels`, `filter?` |
| `query_result` | hub → node | Discovery result | `requestId`, `nodes[]` |
| `request` | **either** | Invoke an action (RPC) | `requestId`, `action`, `payload` |
| `response` | **either** | RPC result | `requestId`, `ok`, `payload`, `error?` |
| `notify` | **either** | One-way push, no reply | `action`, `payload` |
| `goodbye` | node → hub | Graceful shutdown | `reason?` |
| `error` | either | Protocol error | `code`, `message`, `requestId?` |

### Carrying an application protocol

`NodeControlMessage` is `sealed`: an application **cannot** add its own message
types, and `MessageCodec.register` only remaps a wire string onto a built-in.
Three seams carry an application protocol instead:

- **`request`/`response`** — a call that needs an answer, in either direction.
  The `action` string and `payload` object are yours. Correlation, timeouts and
  failure-on-disconnect are handled for you.
- **`notify`** — a push that needs no answer (log batches, progress, status).
  Best-effort: a notify sent while disconnected is dropped and never retried.
- **`heartbeat.payload`** — telemetry a node already reports on the heartbeat
  cadence. Riding the beat avoids a second periodic message; it is ignored by the
  hub's own liveness bookkeeping.

Anything that must survive a disconnect belongs in `request`/`response`, not
`notify`.

Fields marked `?` are omitted from the wire when empty, so a peer that does not
use them sees exactly the pre-1.2 message.

The `descriptor` object is a `NodeDescriptor`:

```json
{
  "id": "worker-1",
  "capabilities": ["transcode", "gpu"],
  "labels": { "region": "eu" },
  "metadata": { "zone": "a" },
  "attributes": { "org": "acme", "services": { "auth": ["login"] } },
  "agentVersion": "1.0.0",
  "status": "online"
}
```

`labels` and `metadata` are flat string→string maps; `attributes` is free-form
JSON that may nest, for application data the hub does not interpret (a service
catalogue, an organisation id). The built-in discovery filters ignore
`attributes` — match on it with a `NodeMatcher` (see below).

## RPC in both directions

`request`/`response` are symmetric. The hub calls a node with
`NodeGateway.request(nodeId, action)`, answered by the node's
`NodeConfig.onRequest`. A node calls the hub with `NodeRuntime.request(action)`,
answered by the hub's `NodeGateway.onRequest`. Each side correlates replies by
`requestId` against its own pending table, so the two directions cannot collide.

**Registration is a precondition for node→hub RPC.** A `request` arriving on a
connection that has not completed `register` is answered
`{"ok": false, "error": "Not registered"}` without reaching the application, so
`onRequest` always receives a live, registered node whose `principal` it can
trust for authorization. Anything a node needs *before* it registers belongs in
the connection handshake or in `register.payload` / `registered.payload`.

An RPC fails fast rather than hanging: if the control connection drops while a
call is in flight, the pending call completes with `NodeUnavailableException`;
if the peer stays silent, it completes with `HubTimeoutException`.

## Enrolment

`register.payload` and `registered.payload` carry application data through
registration, and `NodeGateway.onRegister` vets it. The handler returns the ack
payload, or throws a `HubException` to **reject** — the hub then replies `error`
and closes, and the node never enters the registry (so it is never discoverable
and never heartbeats).

This is the seam for certificate-authority-style enrolment: the node submits a
CSR in `register.payload`, the hub validates and signs it, and the signed
certificate comes back in `registered.payload` (readable node-side via
`NodeRuntime.registration` or `NodeConfig.onRegistered`).

For an in-band challenge/response *before* registration — a signature exchange, a
key agreement — pair the hub's `ConnectionAuthenticator` with the node's
`NodeConfig.onHandshake`. Both run on the raw connection; whatever the handshake
does not consume is replayed, so the control protocol continues normally.

## Application-defined discovery

`query.capability` and `query.labels` are the built-in flat filters. When they
are not expressive enough (version ranges, nested catalogues), a node sends
`query.filter` — free-form JSON — and the hub interprets it with a `NodeMatcher`:

```dart
class CatalogueMatcher implements NodeMatcher {
  @override
  bool matches(NodeDescriptor node, Map<String, dynamic> filter) { ... }
}

NodeGateway(matcher: CatalogueMatcher());
```

`filter` is ignored if the gateway has no matcher configured.

## Lifecycle

```
node                          hub (NodeGateway)
 |--- WS upgrade (auth) ------->|  authenticate; open control channel
 |<== in-band handshake =======>|  optional: ConnectionAuthenticator / onHandshake
 |--- register(payload) ------->|  onRegister vets it (may reject -> error, close)
 |<-- registered(payload) ------|  NodeRegistry.register; advertise heartbeatIntervalMs
 |--- heartbeat(seq, payload) ->|  recordHeartbeat; refresh lastSeen; onHeartbeat
 |<-- heartbeat_ack(seq) -------|
 |          ...                 |  HeartbeatMonitor times out silent nodes
 |--- update(descriptor) ------>|  revise what is advertised (no re-register)
 |--- query ---> query_result ->|  discover peers (capability / labels / filter)
 |<-- request --- response ---->|  hub-initiated RPC   (NodeGateway.request)
 |--- request --- response ---->|  node-initiated RPC  (NodeRuntime.request)
 |--- notify(action, payload) ->|  one-way push, no reply (NodeRuntime.notify)
 |<-- notify(action, payload) --|  one-way push, no reply (NodeGateway.notify)
 |--- goodbye ----------------->|  remove from registry, close
```

A node may pipeline: frames sent after `register` but before `registered` arrives
are queued by the gateway and processed in order once registration settles (and
discarded if it is rejected).

By default a node that disconnects or times out is **removed** from the registry.
Set `NodeGateway.retainNodes` to keep the record instead, marked offline — for a
hub that is the system of record for a known fleet. Either way an offline node is
excluded from discovery.

If the connection drops, the hub removes the node from its registry; the node
transitions through `backoff` and reconnects with exponential backoff
(`ReconnectPolicy`), re-registering on success. All hub-side timing is
`Clock`-driven so it is deterministic under test.

## Versioning

The protocol is intentionally small and additive: new message types are added
via the codec registry without breaking existing peers, and unknown message
types are rejected with an `error` rather than tearing the connection down.
Clustering and multi-hub federation are future extensions layered on this base.
