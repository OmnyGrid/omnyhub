## 1.9.2

### Fixed

- **`204` and `304` responses no longer claim `Content-Type: text/plain`.**
  `dart:io` pre-sets `Content-Type: text/plain; charset=utf-8` on every response
  (dart-lang/sdk#64442), and shelf only ever adds headers. So every `204 No
  Content` and `304 Not Modified` the hub sent carried that type, whether from a
  `HubResponse` with no `Content-Type` or relayed by `ProxyService` from an
  upstream that sent none. On a `304` this is harmful: caches in front of the
  hub (browsers and proxies) merge a `304`'s fields into the stored response,
  so a cached `text/html` page could be relabelled `text/plain`. The transport
  now removes the default from `204`/`304` responses unless the handler set a
  type itself. Every other response keeps the default as before.

### Tests

- `bodyless_response_headers_test.dart` checks the raw heads the hub sends. A
  `304` and a `204` from a `HubResponse` without a type get no `Content-Type`.
  An explicit type on a `304` is kept, and a `200` still gets the default. A
  clean upstream `304` relayed by `ProxyService` gains none. The `304`, `204`
  and `ProxyService` cases fail without the fix.

---

## 1.9.1

### Fixed

- **A revalidated cache entry no longer loses its `Content-Type`.** When a
  stale entry was confirmed by a `304 Not Modified`, `HttpCache.refresh`
  copied every field of the `304` onto the stored response. Dart's
  `HttpServer`, for one, sends its default `Content-Type: text/plain;
  charset=utf-8` on every `304`. So after the first revalidation, a cached
  `text/html` page was served as plain text (browsers then showed its source).
  A `304` confirms the stored body, so the fields that describe that body are
  now never taken from it: every `Content-*` field except `Content-Location`,
  plus `Transfer-Encoding` and `Trailer` (`HttpCache.isRepresentationField`).
  Validators, `Cache-Control`, `Expires`, `Date` and other fields still update
  as before.
- **A `Set-Cookie` on a `304` is no longer shared with other clients.** The
  same merge stored a `304`'s `Set-Cookie` in the entry, so one client's
  cookie (a session id, for example) was then replayed to every client the
  entry was served to. The cookie now goes only to the client whose request
  triggered the revalidation, and is never stored.

### Tests

- A unit test that a `304` carrying `Content-Type`, `Content-Language` and
  `Content-Length` leaves the stored ones intact while `Content-Location` and
  `Cache-Control` update. An integration test revalidates a `text/html` page
  against a real Dart `HttpServer` (whose `304`s carry `text/plain`) and checks
  it stays `text/html`; it fails without the fix.
- A new integration suite, `http_cache_headers_test.dart`, runs 23 cases
  through `HttpRelay` against a real Dart origin:
  - **Header fidelity on hits:** `Content-Type`, `-Language`,
    `-Disposition`, `-Length`, `ETag`, `Last-Modified`, `Expires`, custom
    headers and `Date` are kept; hop-by-hop fields are dropped. Chunked and
    binary bodies replay byte for byte.
  - `HEAD` served from a cached `GET`, and gzip variants kept apart by `Vary`.
  - **Revalidation:** with `ETag` or `Last-Modified` only; a `304` that
    renews the lifetime; a `304`'s `Set-Cookie` reaching only its own client;
    `must-revalidate` versus `max-stale`.
  - **Freshness:** `s-maxage`, `Expires` in the future or past, and the
    default TTL.
  - **Statuses:** a `404` and a `301` cached, a `500` not.
  - **Never shared:** `Set-Cookie`, `private`, `Authorization` and `Range`.
  - **The client's own directives:** hard refresh, `Pragma`, `no-store`,
    `only-if-cached` and conditional requests.
  - **Invalidation and limits:** a `POST` drops its path, and an oversized
    entry isn't stored.
  
  The `Set-Cookie` case fails without the fix.

---

## 1.9.0

A byte-level relay carrying HTTP can now cache responses and enforce timeouts,
the way a reverse proxy does, without ever parsing a request into a framework
object.

Additive and backward-compatible. `HttpRequestHeaderRewriter` behaves exactly as
before (it is now built on the new parser).

### Added

- **`HttpStreamParser`** — an incremental HTTP/1.x parser for either direction
  (`.requests()` / `.responses()`). It emits head, body, end, gap and
  pass-through events that each carry their raw wire bytes, so a relay can
  forward a stream unchanged or replace just a head.
  - Bodies are framed by chunked encoding (extensions and trailers included),
    by `Content-Length`, or, for responses, by the connection closing
    (`close()`).
  - A response parser is told each request's method (`expectResponseTo`): a
    `HEAD`, `204` or `304` response has no body, interim `1xx` responses don't
    answer the request, and a `101` or a successful `CONNECT` switches to
    pass-through.
  - Helpers: `headerValue`, `headerTokens`, `encodeHttpRequestHead`,
    `encodeHttpResponseHead` and the `HttpResponseHead` record.
- **`HttpCache`** — an in-memory, least-recently-used, shared HTTP cache
  following RFC 9111, configured by `HttpCacheOptions` (`maxBytes`,
  `maxEntryBytes`, `cachePrivate`, `defaultTtl`).
  - **What it stores:** `GET` responses with status 200, 203, 204, 301, 308,
    404 or 410 whose length is known. Freshness comes from `s-maxage`, then
    `max-age`, then `Expires`, then the optional default TTL; a zero lifetime
    is stored only with a validator.
  - **What it never stores:** `no-store`, `private` (unless `cachePrivate`),
    responses with `Set-Cookie`, and `Vary: *`.
  - **What bypasses it:** requests with `Authorization`, `Range`, a body or an
    upgrade, and HTTP/1.0.
  - Each `Vary` variant is stored separately.
  - The request's `no-cache`, `max-age`, `min-fresh`, `max-stale`,
    `only-if-cached` and `Pragma: no-cache` are honoured, and
    `must-revalidate` is respected.
  - A `304` refreshes an entry (`refresh`). `canServeStaleOnError` implements
    RFC 5861 `stale-if-error`.
- **`HttpCacheBudget`** — a memory budget shared by several caches. When their
  total exceeds it, the least recently used entry across all of them is
  evicted.
- **`HttpRelay`** — a relay for one client connection over raw bytes, with an
  optional `HttpCache` and `HttpRelayTimeouts`.
  - **Cache outcomes:** a hit is answered locally, a stale entry is revalidated
    with `If-None-Match` / `If-Modified-Since`, and a miss is captured while it
    streams through and stored when complete. A successful unsafe request
    invalidates its target and its `Location` / `Content-Location`. Responses
    carry `X-Cache: HIT | MISS | REVALIDATED | BYPASS | STALE` and `Age`.
  - **Order:** responses stay in request order on keep-alive connections, even
    when a hit is ready before an earlier miss has finished.
  - **Timeouts** (defaults 60s / 5m / 60s / off):
    - no response head in time → `504`;
    - origin closed before responding → `502`;
    - a stall between bytes, or the total deadline passed after the response
      started → close;
    - a client that doesn't finish its request head → `408`.
    
    A `stale-if-error` entry replaces a `502`/`504`. After any failure the
    connection closes, so a late response can never answer the wrong request.
- **`CacheControl`**, `freshnessLifetime`, `parseHttpDate`, `formatHttpDate`,
  `hasValidator` and `cacheableStatuses`.

### Tests

- New unit tests for the parser, Cache-Control, the cache (including the shared
  budget and `Vary`) and the relay (caching, ordering, invalidation and every
  timeout, driven by fake timers). Line coverage is 100% for the parser, cache
  and Cache-Control, and 99% for the relay; the one uncovered line is a
  defensive branch.
- A new integration test runs a real `HttpClient` → `HttpRelay` → `HttpServer`:
  hits, a `304` answered from the cache, `Vary`, a real `504` timeout, and
  pipelined order.

---

## 1.8.0

Forwarding headers for relays that never parse a request: a byte-level TCP
tunnel carrying HTTP can now tell its upstream who the real client is.

Additive and backward-compatible. `ProxyService` is unchanged.

### Added

- **`ForwardedHeaders`** — the facts one proxy hop knows (client address, TLS
  or not, host, port, a `Via` pseudonym, extra context headers, an optional
  request-id minter) and `apply`, which adds them to a plain list of header
  fields. It sets `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`,
  `X-Forwarded-Port`, `X-Forwarded-Ssl`, `X-Real-IP`, RFC 7239 `Forwarded`,
  `Via` and (when asked) `X-Request-Id`. The policy is **append**: values a
  client or earlier proxy sent are kept and this hop's is appended, so an
  upstream trusts only the right-most entry; the single-valued `X-Real-IP`,
  `X-Forwarded-Ssl` and `X-Request-Id` are set only when absent. Values are
  stripped of control characters so none can inject a header line.
- **`HttpRequestHeaderRewriter`** — rewrites the head of *every* request on a
  raw HTTP/1.x client→server byte stream, not just the first: it frames bodies
  by `Content-Length` or chunked encoding (extensions and trailers included)
  and forwards them byte for byte. It switches to pass-through after a protocol
  upgrade (WebSocket) or `CONNECT`, on a close-delimited or ambiguous body, on
  anything that is not HTTP/1.x (including HTTP/2 prior knowledge), and on a
  head over `maxHeadBytes` (64 KiB), so it never buffers more than one head.
- **`HeaderField`** and **`HttpRequestHead`** record typedefs used by both.

### Tests

- Unit tests for both classes (100% line coverage), including every framing
  path fed whole and in 1/3/7-byte pieces; an integration test relaying a real
  `HttpClient` through a raw socket to a real `HttpServer` over one keep-alive
  connection (chunked 70 KB upload, a body that looks like a request, a
  WebSocket); and `ProxyService` coverage for a WebSocket to an unreachable
  upstream and for `forwardWebSocket: false`.

---

## 1.7.0

A node now learns *why* the hub refused its registration, instead of waiting out
the clock.

Additive and backward-compatible.

### Fixed

- **A rejected registration is delivered to the node at once, as a typed
  exception.** When the hub's `onRegister` handler threw, the gateway sent the
  node a `NodeErrorMessage` and closed the connection — but the runtime only
  *logged* that frame and left the registration future pending, so the node
  waited out `registerTimeout` (10s by default) on every attempt before it even
  backed off. The runtime now completes the pending registration with the error
  the frame carries, reconstructed into its `HubException` type by the new
  `hubExceptionForCode`. The connect loop then classifies it through
  `NodeConfig.isTerminal` — a rejection the node cannot fix (a
  `ForbiddenException` for the wrong role, a `ValidationException` for a bad
  descriptor) can end the runtime instead of retrying forever, and either way the
  failure and its reason reach the logger immediately rather than 10 seconds
  later.

### Added

- **`hubExceptionForCode(code, message)`** — reconstructs a `HubException` from
  the `code`/`message` on a wire error frame, the inverse of the gateway's error
  serialization. An unknown code round-trips as an `AppException`, so a newer
  hub's code never degrades to something meaningless on an older node.

---

## 1.6.0

The browser release: a hub can now be called from a web app on another origin,
and push a live event stream to it.

Additive and backward-compatible. Every new parameter defaults to today's
behaviour, and a hub that configures neither feature emits byte-identical
responses — verified by running the full suite unmodified against this release.

### Added

- **CORS.** `cors()` — a `Middleware` that answers a preflight `OPTIONS` itself
  with a `204`, short-circuiting the pipeline so it never reaches routing (where
  it would come back as the router's `405` or the hub's `404`, neither carrying
  CORS headers), and stamps `Access-Control-Allow-Origin` onto every other
  response. Origins come from an exact allow-list, a predicate, or
  `allowAnyOrigin`. `authorization` and `x-omny-principal` are allowed by
  default, because that is what the omny APIs send. `Vary: Origin` is merged into
  any `vary` the handler already set, and a request with no `Origin` header — any
  non-browser client — passes through untouched.

  ```dart
  final hub = OmnyHub(
    transports: [HttpTransport.http(port: 8080)],
    outerMiddleware: [cors(allowedOrigins: ['https://app.example.com'])],
  );
  ```

- **`OmnyHub.outerMiddleware` and `useOuter`.** Middleware composed *outside* the
  hub's error mapping and global authentication, so it sees every response the
  client will actually receive — including the ones `errorMapper` renders from a
  thrown exception — and every request before the authenticator can reject it.

  CORS needs both. Mounted in the ordinary `middleware` layer it can never stamp
  the `401` the authenticator throws, the `404` routing throws, or a `500`, since
  those become responses only *above* it; the browser would then get an opaque
  network error instead of the real status. And a preflight, which by
  specification carries no credentials, would be rejected by a strict
  authenticator before CORS ever saw it. Defaults to empty, in which case the
  pipeline is exactly what it was.

- **Server-Sent Events.** `sseResponse(Stream<SseEvent>)`, `SseEvent`
  (`data`/`event`/`id`/`retry`, plus `SseEvent.json`), `encodeSseEvents`, and the
  lower-level `HubResponse.eventStream`. Events are flushed as they are produced;
  a `: ping` comment every 15s (configurable) keeps the connection alive and is
  what eventually surfaces a client that vanished; `onCancel` then fires so
  per-client resources are released.

  ```dart
  hub.registerService(HandlerService(
    name: 'events', mount: '/events',
    handler: (request) async => sseResponse(bus.stream.map(SseEvent.json)),
  ));
  ```

- **`HubResponse.bufferOutput`.** Whether the transport may buffer the body —
  `true` by default, unchanged. It exists because `dart:io` holds written bytes
  until an 8 KiB buffer fills or the response closes: a live stream closes never
  and its events are tiny, so without this flag a Server-Sent Event would sit in
  the buffer and never reach the browser. `HubResponse.eventStream` sets it
  `false`, and `HttpTransport` translates it into shelf's `shelf.io.buffer_output`
  context key. `HubResponse.stream` accepts it too, for any long-lived push
  stream.

- **`HubResponse.withHeaders`.** A copy with headers merged over the originals,
  carrying the status code, the unread body and `bufferOutput` across — the seam
  middleware needs, `headers` being unmodifiable and `read()` once-only. Reading
  the original afterwards throws, exactly as a second `read()` would.

---

## 1.5.1

### Changed

- **Dependency bump.** `multi_domain_secure_server: ^1.0.17` (from `^1.0.16`) —
  improves error handling and logging in `_accept` and `extractSNIHostname`, the
  path every TLS handshake takes before a `SecurityContext` is chosen, so an SNI
  read that fails now reports why instead of failing silently.
  `meta: ^1.19.0` (from `^1.16.0`).

No API changes; the suite passes unmodified against these versions.

---

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
