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
