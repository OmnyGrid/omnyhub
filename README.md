# OmnyHub

[![pub package](https://img.shields.io/pub/v/omnyhub.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/omnyhub)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/OmnyGrid/omnyhub/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/OmnyGrid/omnyhub/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/OmnyGrid/omnyhub?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyhub/releases)
[![New Commits](https://img.shields.io/github/commits-since/OmnyGrid/omnyhub/latest?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyhub/network)
[![Last Commits](https://img.shields.io/github/last-commit/OmnyGrid/omnyhub?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyhub/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/OmnyGrid/omnyhub?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnyhub/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/OmnyGrid/omnyhub?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnyhub)
[![License](https://img.shields.io/github/license/OmnyGrid/omnyhub?logo=open-source-initiative&logoColor=green)](https://github.com/OmnyGrid/omnyhub/blob/master/LICENSE)

**A reusable, protocol-agnostic HUB framework in pure Dart.**

OmnyHub lets applications build distributed HUB/Node infrastructures over HTTP,
HTTPS, WS and WSS behind one architecture and API. Host many services on a single
port, route on host/path/header/protocol/auth, act as a reverse proxy or gateway
(with automatic Let's Encrypt TLS), and register/discover/health-check remote
nodes — with no assumptions specific to any one application.

```text
                       ┌──────────────────────────── OmnyHub ───────────────────────────┐
   HTTP / HTTPS        │  transports → auth → routing engine → service | proxy target    │
   WS   / WSS   ─────► │   /api/*     ─► ApiService                                        │
   clients            │   /drive/*   ─► ProxyService  ─────────────►  localhost:8081      │
                       │   api.host   ─► ProxyService  ─────────────►  remote upstream     │
                       │   /_node     ─► NodeGateway   ◄─ ws ─ Nodes (register/heartbeat)  │
                       └──────────────────────────────────────────────────────────────────┘
```

```dart
final hub = OmnyHub(transports: [HttpTransport.http(port: 8080)]);
hub.registerService(HandlerService(
  name: 'api', mount: '/api',
  handler: (req) async => HubResponse.json({'ok': true}),
));
hub.route(PathRule('/drive'), ProxyService(Upstream.uri('http://localhost:8081'), name: 'drive'));
await hub.start();
```

## API Documentation

See the full API docs at [pub.dev/documentation/omnyhub][api_doc].

[api_doc]: https://pub.dev/documentation/omnyhub/latest/

## Features

- **Multi-service hosting.** Register many services into one hub and expose them
  through the same server, port and protocol (`/api/*`, `/drive/*`, `/metrics/*`).
  Services are added and removed dynamically.
- **Protocol-agnostic core.** HTTP, HTTPS, WS and WSS on one listener. All
  protocol-specific code (`shelf`, `http`, `web_socket_channel`) is isolated
  behind transport and connection ports; business logic never imports it. Layer
  your own wire protocol with a `ConnectionCodec<T>` + `TypedConnection<T>` to
  exchange decoded frames over any connection.
- **Advanced routing.** Match on host, domain, subdomain (exact, `*.` wildcard
  or **regexp**), path, protocol, headers and authentication state; compose rules
  with `&`, `|`, `~`; drop to a predicate; or plug in a custom routing strategy.
  Extract **path parameters** with `RouterService`/`PathPattern`, or host an
  existing `shelf_router` via `ShelfService`.
- **Layered authentication.** Per-service and global handlers via an
  `AuthCoordinator` that decides authenticate / bypass / delegate / block
  (pre-check), plus per-service `authenticator`/`authorizer` and an in-band
  `ConnectionAuthenticator` for WebSocket handshakes.
- **Reverse proxy & gateway.** Full request/response streaming, `X-Forwarded-*`
  injection, hop-by-hop header stripping and **WebSocket upgrade forwarding**, to
  local or remote upstreams. Host- and path-based gateways and hybrid deployments
  are the same mechanism.
- **Automatic TLS.** Static certificates or automatic Let's Encrypt (ACME
  HTTP-01) provisioning and renewal with hot-reload, behind a single
  `TlsProvider` port — including **dynamic, on-demand multi-domain** issuance via
  SNI, so `foo.example.com`, `bar.example.com`, … are provisioned as they are
  first used, with no code change per domain.
- **Node infrastructure.** A generic control plane for node registration,
  discovery, authentication, capabilities, metadata, health monitoring and
  lifecycle — with reconnection and backoff. **RPC runs in both directions**
  (hub→node and node→hub); registration carries an application payload and is
  vetted by an `onRegister` hook, so a hub can *enrol* nodes (submit a CSR, get a
  signed certificate back); and discovery extends past flat capability/label
  matching via `NodeDescriptor.attributes` + a `NodeMatcher`.
- **Pluggable authentication & authorization.** Bearer, Basic and composite
  authenticators; role-based and predicate authorizers; all fail-closed.
- **Strong typing & clear APIs.** `abstract interface class` ports, `sealed`
  message/exception hierarchies, immutable value objects, hand-written JSON
  codecs, injectable `Clock`/`IdGenerator` for deterministic tests.
- **Tested.** Unit, integration and end-to-end tests over real servers and
  sockets — no mocking library.

## Concepts

| Term | Meaning |
|---|---|
| **Hub** | The facade (`OmnyHub`) that binds transports, hosts services and runs the pipeline. |
| **Transport** | A bound listener on one address/port; normalises traffic into requests/connections. |
| **Service** | A unit of business logic mounted at a path; handles requests and (optionally) WebSockets. |
| **Route / Router** | A rule → service binding; the router selects a route per request (pluggable). |
| **Middleware** | A composable wrapper around the request handler (auth, logging, CORS, …). |
| **Authenticator / Authorizer** | Establish the principal, then gate access (fail-closed). |
| **Upstream / ProxyService** | A reverse-proxy target selector and the service that forwards to it. |
| **TlsProvider** | Supplies the `SecurityContext` (static or auto-provisioned via ACME). |
| **Node / NodeGateway** | A remote participant and the hub-side endpoint it registers with. |

## Architecture

```text
             ┌───────────────────────── data plane ─────────────────────────┐
 request ──► Transport ──► Pipeline (error, ACME, auth, middleware) ──► Router ──► Service
                                                                                 │
                                                                    ┌────────────┴────────────┐
                                                              HandlerService            ProxyService ──► upstream
             ┌──────────────────────── control plane ────────────────────────┐
 node  ◄──ws──► NodeGateway ──► NodeRegistry + Discovery + HeartbeatMonitor
```

```text
lib/
├── omnyhub.dart          # core barrel: transport, http, routing, auth, service, proxy, tls, node registry, hub
├── omnyhub_node.dart     # node-side runtime barrel (OmnyNode/NodeRuntime + core)
├── omnyhub_cli.dart      # config-driven gateway builder (used by bin/omnyhub.dart)
└── src/
    ├── core/       # Message, Connection, Principal, TransportProtocol, ws close codes
    ├── transport/  # Transport port + HttpTransport; tls/ (TlsProvider, StaticTls, LetsEncryptTls)
    ├── http/       # HubRequest, HubResponse, handler typedefs
    ├── routing/    # RouteContext, RouteRule (+ built-ins), Route, Router, RuleRouter
    ├── auth/       # Authenticator, Authorizer + built-ins
    ├── service/    # Service port, HandlerService, ServiceRegistry
    ├── proxy/      # Upstream, ProxyService (HTTP + WS forwarding)
    ├── node/       # control protocol + codec, registry, discovery, heartbeat, gateway, runtime
    ├── hub/        # OmnyHub facade, pipeline, middleware
    ├── cli/        # gateway config builder
    └── shared/     # errors (sealed HubException + ErrorCodes), json, clock, id, logger, version
```

## Getting started

```yaml
dependencies:
  omnyhub: ^0.1.0
```

## Usage

### Library

**Multi-service hosting:**

```dart
final hub = OmnyHub(transports: [HttpTransport.http(port: 8080)]);
hub.registerService(HandlerService(name: 'api',     mount: '/api',     handler: apiHandler));
hub.registerService(HandlerService(name: 'metrics', mount: '/metrics', handler: metricsHandler));
await hub.start();
```

**Advanced routing** (host, header, auth state, host-regexp + path, custom priority):

```dart
hub.route(HostRule('api.example.com'), apiProxy);
hub.route(PathRule('/app') & HeaderRule('x-canary', equals: 'true'), canary, priority: 10);
hub.route(PathRule('/admin') & AuthStateRule.hasRole('admin'), adminService);
hub.route(HostPatternRule(RegExp(r'^(dev|stg)\.example\.com$')) & PathRule('/api'), stagingApi);
```

**Path parameters** (native `RouterService`, or wrap an existing `shelf_router`):

```dart
final drives = RouterService(name: 'drives', mount: '/drives')
  ..get('/drives/<endpoint>/<name>', (req, p) async =>
      HubResponse.json({'endpoint': p['endpoint'], 'name': p['name']}))
  ..get('/drives/<endpoint>/<name>/files/<path|.*>', (req, p) async =>
      HubResponse.text('read ${p['path']}'));
hub.registerService(drives);
// or: hub.registerService(ShelfService(myShelfRouter.call, name: 'x', mount: '/x'));
```

**Layered authentication** (per-service + global coordinator with pre-checks):

```dart
final hub = OmnyHub(
  transports: [HttpTransport.http(port: 8080)],
  authCoordinator: CoordinatorFn((req, route) async {
    if (req.header('x-attack') != null) return const Blocked(TooManyRequestsException());
    if (req.path == '/health') return const Anonymous();  // bypass
    return const Delegate();                                // use per-service handler
  }),
);
hub.registerService(serviceA, authenticator: handlerX);   // A uses X
hub.registerService(serviceB, authenticator: handlerX);   // B uses X
hub.registerService(serviceC, authenticator: handlerY);   // C uses Y
```

**Reverse proxy / gateway** (local, remote, hybrid):

```dart
hub.route(PathRule('/drive'), ProxyService(Upstream.uri('http://localhost:8081'),
    name: 'drive', stripPrefix: '/drive'));
hub.route(HostRule('files.example.com'), ProxyService(Upstream.uri('http://10.0.0.5:9000'),
    name: 'files'));
```

**Authentication & authorization:**

```dart
final hub = OmnyHub(
  transports: [HttpTransport.http(port: 8080)],
  authenticator: BearerTokenAuthenticator({'t0k3n': Principal(id: 'u', roles: {'admin'})}),
  authorizer: const RoleBasedAuthorizer(anyRoles: {'admin'}),
);
```

**Automatic TLS** (fixed domains):

```dart
final hub = OmnyHub(transports: [
  HttpTransport.http(port: 80),                       // answers ACME challenges
  HttpTransport.https(port: 443, tls: LetsEncryptTls(
    domains: [Domain(name: 'api.example.com', email: 'ops@example.com')],
    cacheDir: '/var/lib/omnyhub/certs',
    production: true,
  )),
]);
```

**Dynamic / on-demand TLS** (any allowed host, provisioned on first use, served
via SNI):

```dart
final hub = OmnyHub(transports: [
  HttpTransport.http(port: 80),
  HttpTransport.https(port: 443, tls: LetsEncryptTls.onDemand(
    email: 'ops@example.com',
    allowDomain: (host) => host.endsWith('.example.com'),
    cacheDir: '/var/lib/omnyhub/certs',
    production: true,
  )),
]);
// foo.example.com and bar.example.com now get certificates automatically.
// (Clients must send SNI — all modern browsers do.)
```

**Nodes** (control plane):

```dart
// Hub side:
final gateway = NodeGateway();
await hub.registerService(gateway);
final workers = gateway.discover(capability: 'transcode');
final result = await gateway.request(workers.first.id, 'encode', payload: {'job': 'a.mp4'});

// Node side (package:omnyhub/omnyhub_node.dart):
final node = OmnyNode(NodeConfig(
  hubUri: Uri.parse('ws://hub.local/_node'),
  nodeId: NodeId('worker-1'),
  capabilities: {'transcode'},
  headers: {'authorization': 'Bearer <token>'},
));
await node.start();
```

### CLI

`omnyhub` launches a config-driven reverse-proxy / gateway from a JSON file:

```sh
dart run omnyhub gateway.json
```

```json
{
  "listen": [ { "protocol": "http", "port": 8080 } ],
  "routes": [
    { "path": "/api",  "target": "http://localhost:9000", "stripPrefix": "/api" },
    { "host": "drive.example.com", "target": "http://localhost:9001", "priority": 10 }
  ]
}
```

TLS listeners accept `"cert"`/`"key"` (static) or a `"letsencrypt"` block.

## How it works

1. Each **transport** binds one address/port and normalises inbound traffic into
   a `HubRequest` (or, on upgrade, a `Connection`).
2. The request runs through the **pipeline**: error mapping, ACME challenge
   (if any), authentication (attaching a `Principal`), then user middleware.
3. The **router** builds a `RouteContext` (host split into domain/subdomain,
   path, protocol, headers, principal) and selects the best matching route.
4. The **authorizer** gates the request, then the matched **service** handles it
   — a local handler, or a **proxy** that streams to an upstream (forwarding
   WebSocket upgrades too).
5. **Nodes** connect out to the `NodeGateway` over WebSocket, authenticate,
   register capabilities, and heartbeat; the hub tracks them in a `NodeRegistry`,
   answers discovery queries, and can invoke RPCs on them. See
   [doc/protocol.md](doc/protocol.md) and [doc/security.md](doc/security.md).

## Examples

See [`example/`](example/):

| Example | Shows |
|---|---|
| [service_hosting_example.dart](example/service_hosting_example.dart) | Multiple services (HTTP + WS) on one port; dynamic add/remove. |
| [reverse_proxy_example.dart](example/reverse_proxy_example.dart) | Path- and host-based proxying + a local service (hybrid). |
| [auto_tls_example.dart](example/auto_tls_example.dart) | HTTPS with a static cert; a Let's Encrypt config sketch. |
| [lets_encrypt_example.dart](example/lets_encrypt_example.dart) | Full automatic-TLS HTTPS via Let's Encrypt (ACME); dry-run by default. |
| [path_params_example.dart](example/path_params_example.dart) | Path-parameter routing with `RouterService`. |
| [layered_auth_example.dart](example/layered_auth_example.dart) | Per-service + global auth and host-regexp routing. |
| [node_example.dart](example/node_example.dart) | A node registering, discovery, heartbeats and RPC. |

## Running the tests

```sh
dart pub get
dart analyze --fatal-infos --fatal-warnings .
dart test
```

Tests use real loopback HTTP/WS(S) servers and in-memory fakes — no mocking
library. TLS tests use the committed self-signed fixtures under
`test/support/certs/`. Live Let's Encrypt issuance is not exercised in CI (no
public CA); the ACME provisioning seam is unit-tested and verified manually
against the staging endpoint.

## Status

`0.1.0` — the full framework: multi-service hosting, advanced routing,
authentication/authorization, reverse proxy (HTTP + WebSocket), automatic TLS,
and the node control plane (registration, discovery, health, RPC, reconnection),
all covered by unit, integration and end-to-end tests. Clustering and multi-hub
federation are planned extensions layered on the node protocol.

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
