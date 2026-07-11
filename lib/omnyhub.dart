/// OmnyHub — a reusable, protocol-agnostic HUB framework.
///
/// This is the core barrel: the transport-agnostic building blocks (messages,
/// connections, requests), the routing engine, authentication and
/// authorization, service hosting, the reverse proxy, automatic TLS, the node
/// registry, and the [OmnyHub] facade that ties them together.
///
/// Applications building a *node* (a remote participant that connects out to a
/// hub) should import `package:omnyhub/omnyhub_node.dart` instead, which layers
/// the node runtime on top of this library.
///
/// ```dart
/// final hub = OmnyHub(transports: [HttpTransport.http(port: 8080)]);
/// hub.registerService(
///   HandlerService(name: 'api', mount: '/api', handler: (req) async {
///     return HubResponse.ok('hello');
///   }),
/// );
/// await hub.start();
/// ```
library;

// Shared.
export 'src/shared/errors/error_codes.dart';
export 'src/shared/errors/hub_exception.dart';
export 'src/shared/json/json.dart';
export 'src/shared/utils/clock.dart';
export 'src/shared/utils/id_generator.dart';
export 'src/shared/utils/logger.dart';
export 'src/shared/version.dart';

// Core.
export 'src/core/connection.dart';
export 'src/core/message.dart';
export 'src/core/principal.dart';
export 'src/core/transport_protocol.dart';
export 'src/core/ws_close.dart';

// HTTP model.
export 'src/http/handler.dart';
export 'src/http/hub_request.dart';
export 'src/http/hub_response.dart';

// Transport.
export 'src/transport/http_transport.dart';
export 'src/transport/tls/lets_encrypt_tls.dart';
export 'src/transport/tls/static_tls.dart';
export 'src/transport/tls/tls_provider.dart';
export 'src/transport/transport.dart';
export 'src/transport/web_socket_connection.dart';
// Re-exported so `LetsEncryptTls(domains: [Domain(...)])` needs no extra import.
export 'package:shelf_letsencrypt/shelf_letsencrypt.dart'
    show Domain, CheckCertificateStatus;

// Auth.
export 'src/auth/authenticator.dart';
export 'src/auth/authorizer.dart';
export 'src/auth/basic_authenticator.dart';
export 'src/auth/token_authenticator.dart';

// Routing.
export 'src/routing/route.dart';
export 'src/routing/route_context.dart';
export 'src/routing/route_rule.dart';
export 'src/routing/rules.dart';

// Services.
export 'src/service/handler_service.dart';
export 'src/service/service.dart';
export 'src/service/service_registry.dart';

// Reverse proxy.
export 'src/proxy/proxy_service.dart';
export 'src/proxy/upstream.dart';

// Nodes (control-plane protocol, registry and hub-side gateway).
export 'src/node/heartbeat_monitor.dart';
export 'src/node/message_codec.dart';
export 'src/node/node_control_message.dart';
export 'src/node/node_descriptor.dart';
export 'src/node/node_gateway.dart';
export 'src/node/node_id.dart';
export 'src/node/node_registry.dart';

// Hub.
export 'src/hub/omny_hub.dart';
export 'src/hub/pipeline.dart';
