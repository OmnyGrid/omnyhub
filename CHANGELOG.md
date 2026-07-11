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
