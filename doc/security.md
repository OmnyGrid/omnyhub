# OmnyHub security model

## Transport security

OmnyHub serves plaintext (`http`/`ws`) or TLS (`https`/`wss`) transports. TLS
material is supplied by a `TlsProvider`:

- **`StaticTls`** — a fixed certificate and key (from PEM files, PEM strings or
  a pre-built `SecurityContext`).
- **`LetsEncryptTls`** — automatic provisioning and renewal via Let's Encrypt
  (ACME HTTP-01). The hub mounts the ACME challenge responder on its plaintext
  (port 80) transport, provisions certificates before binding the HTTPS
  listener, and hot-reloads (rebinds) the listener when a certificate renews.
  Defaults to the **staging** ACME endpoint; switch to production explicitly
  once issuance works.

WebSocket upgrades are served on the same listener as HTTP requests, so a single
port carries both. The `wss://` scheme is simply a WebSocket upgrade on a TLS
transport.

## Authentication

`Authenticator` establishes the `Principal` behind each request, with a
fail-closed contract:

- no credentials → anonymous (`null`);
- credentials present but invalid → `UnauthorizedException` (HTTP 401);
- valid → a `Principal`.

Built-ins: `BearerTokenAuthenticator`, `BasicAuthAuthenticator`,
`CompositeAuthenticator`, and the default `AnonymousAuthenticator`. The
authenticated principal is attached to the request early in the pipeline, so
auth-dependent routing (`AuthStateRule`) and authorization both see it.

Node connections authenticate the same way: credentials travel in the WebSocket
upgrade headers and are validated by the hub's `Authenticator` during the
upgrade, before the control channel opens.

## Authorization

Two complementary layers:

- **Route-level** — an `AuthStateRule` on a route requires authentication or
  specific roles to *reach* a service (`hub.route(PathRule('/admin') &
  AuthStateRule.hasRole('admin'), adminService)`).
- **Hub-wide** — an `Authorizer` is a global gate consulted after routing.
  Built-ins: `RoleBasedAuthorizer`, `AllowAllAuthorizer` (default),
  `DenyAllAuthorizer`, `PredicateAuthorizer`. Denial yields HTTP 403; for
  WebSocket upgrades the connection is closed with code 4403.

Both authenticator and authorizer default to permissive/anonymous so the
framework is unopinionated out of the box, but every built-in *policy* fails
closed when a requirement is unmet.

## Reverse proxy

The proxy strips hop-by-hop headers (`Connection`, `Keep-Alive`,
`Transfer-Encoding`, `Upgrade`, …) in both directions, rewrites the `Host`
header to the upstream authority, and injects `X-Forwarded-For`,
`X-Forwarded-Proto` and `X-Forwarded-Host` so upstreams can reconstruct the
original request. Because a `ProxyService` is an ordinary service, the auth and
routing pipeline applies to proxied traffic exactly as to local services.

## Error surface

All framework failures are the sealed `HubException` hierarchy, each carrying a
stable snake-case `code` (see `ErrorCodes`) and an HTTP `statusCode`. Errors are
rendered as a JSON envelope `{"error": {"code", "message"}}`; internal errors
never leak stack traces to clients.
