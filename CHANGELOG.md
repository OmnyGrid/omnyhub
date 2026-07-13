## 1.5.0

### Added

- **`LetsEncryptTls.renewBefore`.** How much validity a certificate must have
  left to be kept; below it, `maybeRenew` renews. Defaults to 5 days — the
  previous, hard-coded `shelf_letsencrypt` behaviour — so nothing changes unless
  you set it.

  5 days is a thin margin: a certificate is renewed at most one
  `OmnyHub.tlsRenewalInterval` (12h by default) after dropping below the
  threshold, and a failed renewal then has very little room to retry before the
  certificate actually expires. Let's Encrypt's own advice is to renew with
  roughly a third of the lifetime left (30 of 90 days). Applications that were
  previously enforcing their own margin — refusing to serve a near-expiry
  certificate, and reissuing — can now express it here instead:

  ```dart
  LetsEncryptTls.onDemand(
    allowDomain: ...,
    cacheDir: '/etc/letsencrypt/live',
    renewBefore: const Duration(days: 15),
  );
  ```

  A certificate that is still valid keeps being served while it renews in the
  background; only an *expired* one is withheld (`isHandledDomainCertificate`
  already rejects an expired, corrupt or unloadable certificate before any
  `SecurityContext` is built, so an expired certificate is never served).

## 1.4.0

On-demand TLS release — the seams an application needs to decide *its own way*
whether a host may be certified, rather than reimplementing the SNI cache and
issuance around `LetsEncryptTls`. Driven by adopting omnyhub in MenuIci's
`sites_server`, whose front door had grown a parallel copy of both.

Additive and backward-compatible: `DomainPolicy` is *widened*, so existing
synchronous policies still satisfy it, and `autoIssue` defaults to the 1.3.0
behaviour. Verified by running the full suite unmodified against this release.

### Added

- **Asynchronous domain policy.** `DomainPolicy` is now
  `FutureOr<bool> Function(String host)` (was `bool Function(String host)`), so
  on-demand issuance can be gated by a real lookup — a database query, a tenant
  API call — instead of only what is knowable synchronously. Previously an
  application whose "may this host be certified?" answer lived behind I/O had to
  keep a hand-rolled cache beside the hub and pre-warm it, which is exactly the
  duplication `allowDomain` exists to remove. Existing sync policies are
  unaffected: `bool` is a subtype of `FutureOr<bool>`.
- **`LetsEncryptTls.autoIssue`.** When `false`, only certificates already cached
  in `cacheDir` are served and the CA is never contacted — neither on a
  handshake miss nor from the renewal loop. For a deployment whose certificates
  are provisioned out-of-band (certbot, a secrets mount, a sibling process),
  which previously could not be expressed through this provider at all.

### Changed

- **`LetsEncryptTls.isAllowed` returns `Future<bool>`.** It awaits the policy.
  The synchronous SNI path (`TlsProvider.contextFor`, which cannot await) no
  longer calls it: `contextFor` now schedules `obtain()` in the background, and
  `obtain()` is the single place the policy is evaluated. The only breaking
  change, and only for code calling `isAllowed` directly.
- **A rejected host is no longer re-checked on every handshake.** With a sync
  policy the pre-check in `contextFor` was free; with an async one it could be
  an HTTP call per TLS handshake. Rejections are now remembered in a bounded
  cache (capped, so an SNI flood of random hostnames cannot grow it without
  limit).
- **`obtain()` stays de-duplicated under an async policy.** It registers its
  in-flight future *before* the first suspension, so concurrent handshakes for
  the same host still share one provisioning attempt now that the allow-check
  can itself suspend.

## 1.3.0

Control-plane release — the seams an application needs to host its *own* node
protocol on `NodeGateway`/`NodeRuntime` rather than reimplementing the registry,
heartbeat watchdog and RPC correlation around them. Driven by adopting omnyhub in
OmnyServer, whose hub/agent had grown a parallel copy of all three.

Additive and backward-compatible: every new field is omitted from the wire when
empty, every new hook defaults to `null`, and every new option defaults to the
1.2.0 behaviour. Verified by running the omnydrive and omnyshell suites
unmodified against this release.

### Added

- **Heartbeat telemetry.** `Heartbeat.payload` carries application data on the
  beat (a metrics snapshot, a queue depth), produced by
  `NodeConfig.heartbeatPayload` and consumed by `NodeGateway.onHeartbeat`. Saves
  a second periodic message for telemetry a node already reports on the same
  cadence. A payload builder that throws or stalls never costs the node its
  liveness — the beat goes out empty.
- **One-way push (`NodeNotify`).** The fire-and-forget counterpart of
  `NodeRequest`: same `action` + `payload`, no correlation id, no reply. Sent
  with `NodeRuntime.notify` / `NodeGateway.notify`, received via
  `NodeGateway.onNotify` / `NodeConfig.onRequest`. Previously a node could only
  push by calling `request` and discarding a response it did not want.
- **Connection lifecycle hooks.** `NodeGateway.onConnect` / `onDisconnect` /
  `onTimeout` observe a control connection opening and closing, so an application
  can audit, persist or publish on every transition. `onConnect` fires for
  sockets that never register — which the registry's events cannot see at all —
  and `onDisconnect` hands over the whole `RegisteredNode`, not just a
  descriptor.
- **Node retention.** `NodeGateway.retainNodes` keeps a disconnected or
  timed-out node in the registry, marked offline, instead of dropping the record.
  For a hub that is the system of record for a known fleet: an offline node stays
  queryable by `NodeRegistry.byId` with its last-known descriptor and
  re-registers into the same slot. Offline nodes are excluded from `discover`
  either way. Backed by a new `NodeRegistry.markOffline` and
  `NodeEventKind.disconnected`.
- **Per-node application state.** `RegisteredNode.state`, a mutable bag the
  application owns. The registry constructs `RegisteredNode` itself, so
  subclassing it to add fields never worked; the pre-existing `activeSessions`
  field was the one hardcoded concession to this.
- **`NodeEvent.node`** exposes the affected `RegisteredNode` — its connection,
  principal and state — so a subscriber no longer has to re-look-up the registry
  to act on an event.
- **Injectable node transport.** `NodeConfig.connect` replaces the built-in
  WebSocket dial, for a transport omnyhub does not ship and for driving a
  `NodeRuntime` against a loopback connection in tests. `NodeConfig.pingInterval`
  exposes WebSocket-level keepalive, which the runtime previously never passed.
- **`NodeConfig.descriptorBuilder`** rebuilds the advertised descriptor on every
  connection attempt, replacing the static one assembled at construction. A node
  that changes while it is running — a GPU driver lands, a runtime is installed,
  a label is retagged — now advertises the change on its next (re)registration
  instead of being stuck with what it knew at startup.
- **Terminal-failure policy.** `NodeConfig.isTerminal` ends the runtime instead
  of retrying, with the cause left in `NodeRuntime.terminalError`. Reconnecting
  cannot fix a revoked key or a refused enrolment — it just hammers the hub
  forever, which is what a node did before this.
- **`AppException`**, a public `HubException` an application raises with its own
  `code` and `statusCode`. `HubException` is `sealed`, so an application could not
  slot its own failures into the hierarchy, and everything that maps errors to the
  wire keys off `HubException` — so an application error became an opaque 500.
- **`WsCloseCodes.forException`**, the single `HubException` → close-code mapping,
  replacing a private copy duplicated in `OmnyHub` and `NodeGateway`. It now maps
  502/503/504 to `badGateway`; previously every status outside 401/403/404 fell
  through to `unauthorized`, so an unavailable node was reported to the peer as an
  auth failure.
- **`TypedConnection.onDecodeError`** observes frames the codec rejects. Dropping
  them is deliberate — one bad frame must not tear the connection down — but it
  was also invisible, hiding version skew and codec bugs.
- **`LoggerBase`**, a mixin deriving `debug`/`info`/`warn`/`error` from `log`, so
  a `Logger` adapter implements two methods instead of six.

### Fixed

- **Frames sent during registration were silently dropped.** `NodeGateway` ran
  `onRegister` without awaiting it before dispatching further frames, so anything
  arriving while an async handler was in flight raced an unset registration and
  was discarded (`Heartbeat`, `NodeUpdate`) or refused as `Not registered`
  (`NodeRequest`). A node may pipeline after `register` without waiting for its
  ack, and any `onRegister` doing real work (vetting a CSR, writing to a repo)
  widened the window. Such frames are now queued and replayed in order once
  registration settles, and discarded if it is rejected.
- **A stray binary frame could take down the gateway.** `MessageCodec.decode`
  UTF-8-decoded a `BinaryMessage` outside its guard, so arbitrary bytes escaped as
  a raw `FormatException` — past `NodeGateway`'s `HubException`-only catch — and
  surfaced as an uncaught async error. Decode failures are now always a
  `ProtocolException`, the peer gets a `NodeErrorMessage`, and the connection
  keeps serving.

### Changed

- `MessageCodec`'s documentation claimed third parties could register new message
  types. They cannot: `NodeControlMessage` is `sealed`, so a decoder can only ever
  return a built-in, and `register` merely remaps a wire string onto one.
  Application protocols ride on `NodeRequest`/`NodeResponse` and `NodeNotify`,
  which is now what the docs say.

## 1.2.0

Control-plane release — the node protocol grows the pieces an application needs
to run a real HUB/Node infrastructure on it (enrolment, node-initiated calls,
domain-specific discovery) instead of only the "worker node" shape. Fully
backward-compatible (additive): every new field is omitted from the wire when
empty and every new hook defaults to `null`, so existing peers and callers are
unaffected.

### Added

- **Bidirectional RPC.** `request`/`response` now flow in both directions. A node
  calls the hub with `NodeRuntime.request(action, payload:)`, answered by the
  hub's new `NodeGateway.onRequest` handler — which receives the calling
  `RegisteredNode`, so the hub knows who is asking and can authorize on its
  `principal`. Registration is a precondition: a request from a connection that
  has not registered is rejected (`error: "Not registered"`) without reaching the
  handler. The existing hub→node direction (`NodeGateway.request`) is unchanged.
  Previously the only node-initiated message was `query`, so an application
  needed a second channel back to the hub.
- **Enrolment.** `NodeRegister` and `NodeRegistered` carry a
  `Map<String, dynamic> payload`, and `NodeGateway.onRegister` vets registrations
  — returning the ack payload, or throwing a `HubException` to **reject** (the
  hub replies `error`, closes, and never registers the node). Node-side:
  `NodeConfig.registerPayload` / `NodeConfig.onRegistered` and
  `NodeRuntime.registration`. This is the seam for CA-style enrolment: submit a
  CSR, get a signed certificate back.
- **Node-side in-band handshake.** `NodeConfig.onHandshake` runs on the raw
  connection before registering — the counterpart of the hub's existing
  `ConnectionAuthenticator`, so a node can now answer a challenge/response or
  key-agreement exchange. Unconsumed frames are replayed to the control protocol.
- **Application-defined discovery.** `NodeDescriptor.attributes`
  (`Map<String, dynamic>`, may nest — unlike the flat string-only `labels` and
  `metadata`), `NodeQuery.filter`, and the `NodeMatcher` port, so an application
  owns query semantics the hub cannot know about (version ranges, nested service
  catalogues). `NodeRegistry.discover` takes a `where` predicate.
- **`NodeUpdate`** (`t: "update"`) — a node revises its advertised descriptor
  without re-registering (`NodeRuntime.updateDescriptor`,
  `NodeRegistry.updateDescriptor`, `NodeEventKind.updated`).
- `Json.optObject` for reading free-form JSON object fields.

### Changed

- `NodeGateway.codec` and `NodeRuntime.codec` are now typed
  `ConnectionCodec<NodeControlMessage>` rather than the concrete `MessageCodec`,
  so an application can supply its own wire format (e.g. binary) without forking
  either endpoint. `MessageCodec.standard()` remains the default; source-
  compatible for existing callers.

### Fixed

- **In-flight RPCs no longer hang when a connection drops.** `NodeGateway` and
  `NodeRuntime` now fail their pending calls with `NodeUnavailableException` on
  disconnect, goodbye and heartbeat timeout, instead of leaving callers to wait
  out their own timeout. `NodeRuntime`'s pending discovery queries were leaked on
  disconnect and are now cleared too.

## 1.1.0

Synergy release — shared primitives that let protocol-oriented apps (like
OmnyShell) ride on omnyhub's transport without a reverse-adapter, and make TLS
renewal seamless. Fully backward-compatible (additive).

### Added

- **`ConnectionCodec<T>` + `TypedConnection<T>`** — a first-class "codec over a
  raw duplex connection" primitive. A protocol supplies a
  `ConnectionCodec<AppFrame>` (mapping its frames to `Message`s) and exchanges
  decoded values over any omnyhub `Connection`; undecodable inbound frames are
  dropped. omnyhub's node `MessageCodec` is now a
  `ConnectionCodec<NodeControlMessage>`, and the node runtime consumes a
  `TypedConnection`.

### Changed

- **Gap-free TLS rebind.** `HttpTransport.rebind()` now binds a fresh `shared`
  listener on the **same** port with the renewed certificate and drains the old
  one gracefully (`force: false`) — live connections survive certificate renewal
  instead of being dropped. Benefits automatic Let's Encrypt renewal.
- **`ReloadableFileTls`** detects changes by **byte content** (not mtime+size),
  so same-size rotations are caught and a partial write that fails to parse
  keeps the previous certificate.

## 1.0.0

First stable release. OmnyHub is a reusable, protocol-agnostic HUB framework for
building distributed HUB/Node infrastructures over HTTP/HTTPS/WS/WSS behind one
architecture and API.

### Features

- **Multi-service hosting.** Host many `Service`s on one `OmnyHub` instance,
  exposed through the same server, port and protocol (`/api/*`, `/drive/*`,
  `/metrics/*`, …). Services register and unregister dynamically.
- **Protocol-agnostic transport.** HTTP, HTTPS, WS and WSS on a single `shelf`
  listener behind a `Transport` port; a `Connection`/`Message` abstraction for
  the WebSocket control plane. All protocol-specific code is isolated from
  business logic.
- **Advanced routing.** Match on host, domain and subdomain (exact, `*.`
  wildcard, or **regexp** via `HostPatternRule`), path prefix, **path parameters**
  (`RouterService`/`PathPattern`, or an existing `shelf_router` via
  `ShelfService`), protocol, headers, method and authentication state. Compose
  rules with `&`/`|`/`~`, use a predicate, or plug in a custom `Router`.
- **Reverse proxy & gateway.** `ProxyService` streams HTTP requests/responses,
  injects `X-Forwarded-*`, strips hop-by-hop headers, and forwards WebSocket
  upgrades — to local or remote upstreams. Host- and path-based gateways and
  hybrid (local + proxied) deployments.
- **Automatic TLS.** `StaticTls`, `ReloadableFileTls` (hot-reload cert files),
  and `LetsEncryptTls` (ACME HTTP-01) with provisioning, renewal and hot-reload —
  including **dynamic, on-demand multi-domain** issuance via SNI (a domain policy
  and per-host, optionally async, contact-email resolver), so new subdomains are
  provisioned as they are first used.
- **Layered authentication & authorization.** A global `AuthCoordinator`
  deciding authenticate / bypass / delegate / block (pre-check), **per-service**
  authenticators and authorizers, and an in-band `ConnectionAuthenticator` for
  WebSocket handshakes. Built-in Bearer/Basic/composite authenticators and
  role-based/predicate authorizers, all fail-closed.
- **Node infrastructure.** A generic control protocol + extensible `MessageCodec`,
  `NodeGateway`, `NodeRegistry`, capability/label discovery, `HeartbeatMonitor`,
  and a node-side `NodeRuntime`/`OmnyNode` with registration, heartbeats, RPC,
  peer discovery and reconnection with backoff.
- **Demo CLI** (`bin/omnyhub.dart`) that launches a config-driven
  reverse-proxy/gateway, runnable examples, and `doc/protocol.md` +
  `doc/security.md`.
- **Tested.** Unit, integration and end-to-end tests over real servers and
  sockets — no mocking library.

The `0.x` entries below record the incremental pre-release development.

## 0.3.0

### Added

- **Path-parameter routing.** `PathPattern` (named `<param>` + wildcard tail
  `<name|.*>`) and `RouterService` (intra-service method dispatch exposing
  captured params, 405/404). `ShelfService` adapts an existing `shelf.Handler` /
  `shelf_router.Router` verbatim.
- **Layered authentication framework.** A global `AuthCoordinator` returning a
  sealed `AuthDecision` (`Authenticated` / `Anonymous` bypass / `Delegate` to the
  service's authenticator / `Blocked` pre-check), **per-service**
  `authenticator`/`authorizer` on `registerService`/`route`, and
  `TooManyRequestsException` (429). Fully backward-compatible
  (`DefaultAuthCoordinator`).
- **In-band connection authentication.** `ConnectionAuthenticator` + a
  `HandshakeConnection` buffered wrapper so a WebSocket handshake can authenticate
  and then hand the live connection to the service (single-subscription safe).
- **Host/domain regexp routing.** `HostPatternRule(RegExp, {part})` matching the
  host, domain or subdomain, combinable with a `PathRule` via `&`.
- **`ReloadableFileTls`** — a `TlsProvider` that hot-reloads certificate/key files
  when they change on disk (cert-manager/certbot friendly).
- **Pipeline helpers** — `mapErrors` middleware (map app exceptions to responses)
  and `successEnvelope`/`errorEnvelope` (`{success, data}` / `{success, error}`).
- **`NodeRegistry` extras** — `RegisteredNode.activeSessions`/`connectionId`,
  `NodeRegistry.byConnectionId`/`updateActiveSessions`.
- Examples: `path_params_example.dart`, `layered_auth_example.dart`.

## 0.2.0

### Added

- **Dynamic / on-demand Let's Encrypt domains.** `LetsEncryptTls` now accepts an
  `allowDomain` policy (via `LetsEncryptTls.onDemand(...)` or the main
  constructor) to provision certificates for any allowed host on demand, served
  via SNI from a live per-host cache — so `foo.example.com`, `bar.example.com`, …
  work without listing each domain in code. New `obtain(host)`, `isAllowed(host)`
  and `isOnDemand` APIs. The ACME contact email may be a fixed `onDemandEmail`
  or resolved per host with an async `onDemandEmailResolver` (e.g. a per-tenant
  lookup).
- **SNI transport binding.** `HttpTransport` serves multiple certificates on one
  TLS listener via SNI when its TLS provider implements the new `SniTlsProvider`
  capability; a certificate obtained on demand is served on the next handshake
  with no rebind. Clients must send SNI (all modern browsers do).
- `HandlerService.handlesWebSocket` getter and expanded WebSocket docs.
- New `example/lets_encrypt_example.dart` (fixed and `--on-demand` modes).

### Changed

- `LetsEncryptTls` requires seed `domains` and/or an `allowDomain` policy;
  `allowDomain` requires an `onDemandEmail`.

## 0.1.0

- **Initial release of OmnyHub** — a reusable, protocol-agnostic HUB framework.

### Added

- **Multi-service hosting.** `OmnyHub` binds one or more transports and hosts
  many `Service`s on the same port, with dynamic registration/removal.
- **Transports.** `HttpTransport` serves HTTP/HTTPS/WS/WSS on one `shelf`
  listener behind a `Transport` port; `Connection`/`Message` abstract the
  WebSocket control channel.
- **Advanced routing.** `RouteContext` + composable `RouteRule`s (path, host,
  domain, subdomain, header, protocol, method, auth-state, `and`/`or`/`not`,
  predicate) selected by a pluggable `Router` (default `RuleRouter`).
- **Authentication & authorization.** Bearer/Basic/composite authenticators and
  role-based/predicate authorizers, wired fail-closed into the request pipeline.
- **Reverse proxy.** `ProxyService` streams HTTP requests/responses, injects
  `X-Forwarded-*`, strips hop-by-hop headers, and forwards WebSocket upgrades to
  local or remote upstreams; host- and path-based gateways and hybrid modes.
- **Automatic TLS.** `TlsProvider` with `StaticTls` and `LetsEncryptTls` (ACME
  HTTP-01 via `shelf_letsencrypt`) — provisioning, challenge auto-mount and
  hot-reload on renewal.
- **Node infrastructure.** A generic control protocol + `MessageCodec`,
  `NodeGateway`, `NodeRegistry`, discovery, `HeartbeatMonitor`, and a node-side
  `NodeRuntime`/`OmnyNode` with registration, heartbeats, RPC, peer discovery and
  reconnection with backoff.
- **Demo CLI.** `bin/omnyhub.dart` launches a config-driven reverse-proxy/gateway.
- Unit, integration and end-to-end tests over real servers and sockets.
