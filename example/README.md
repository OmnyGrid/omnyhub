# OmnyHub examples

Each example is self-contained: it starts an in-process hub over loopback, runs
a scenario, prints the results, and shuts everything down.

| Example | Shows |
|---|---|
| [`service_hosting_example.dart`](service_hosting_example.dart) | Hosting multiple services (HTTP + WebSocket) on one port, with dynamic add/remove. |
| [`reverse_proxy_example.dart`](reverse_proxy_example.dart) | Path- and host-based reverse proxying to a backend, mixed with a local service (hybrid). |
| [`auto_tls_example.dart`](auto_tls_example.dart) | Serving HTTPS with a static certificate; configuring automatic Let's Encrypt TLS. |
| [`node_example.dart`](node_example.dart) | A worker node registering with a hub, discovery, heartbeats and an RPC. |

Run any example with:

```sh
dart run example/<name>.dart
```
