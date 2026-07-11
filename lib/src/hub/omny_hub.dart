import 'dart:async';

import '../auth/authenticator.dart';
import '../auth/authorizer.dart';
import '../core/connection.dart';
import '../core/ws_close.dart';
import '../http/handler.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../routing/route.dart';
import '../routing/route_context.dart';
import '../routing/route_rule.dart';
import '../routing/rules.dart';
import '../service/service.dart';
import '../service/service_registry.dart';
import '../shared/errors/hub_exception.dart';
import '../shared/utils/clock.dart';
import '../shared/utils/id_generator.dart';
import '../shared/utils/logger.dart';
import '../transport/http_transport.dart';
import '../transport/transport.dart';
import 'pipeline.dart';

/// The framework facade: binds one or more [Transport]s, hosts a set of
/// [Service]s on them, and runs every request through a middleware pipeline.
///
/// ```dart
/// final hub = OmnyHub(transports: [HttpTransport.http(port: 8080)]);
/// hub.registerService(HandlerService(
///   name: 'api', mount: '/api',
///   handler: (req) async => HubResponse.json({'ok': true}),
/// ));
/// await hub.start();
/// ```
///
/// Services can be registered and removed dynamically, before or after
/// [start]. Advanced routing, authentication and reverse proxying build on this
/// core.
class OmnyHub {
  final List<Transport> _transports;
  final ServiceRegistry _services = ServiceRegistry();
  final List<Route> _routes = [];
  final List<Middleware> _middleware;

  /// The routing strategy that selects a service for each request. Defaults to
  /// [RuleRouter]; inject a custom [Router] for bespoke strategies.
  final Router router;

  /// Establishes the principal behind each request. Defaults to
  /// [AnonymousAuthenticator] (everyone anonymous).
  final Authenticator authenticator;

  /// The hub-wide authorization gate. Defaults to [AllowAllAuthorizer].
  final Authorizer authorizer;

  /// The logger used by the hub and its default middleware.
  final Logger logger;

  /// The clock used for pipeline timing and (later) node liveness.
  final Clock clock;

  /// The id generator used for connection/request ids.
  final IdGenerator idGenerator;

  /// How often to check for TLS certificate renewal. `Duration.zero` disables
  /// the scheduler.
  final Duration tlsRenewalInterval;

  bool _running = false;
  Timer? _renewalTimer;
  late HubRequestHandler _composed = errorMapper(logger: logger)(_dispatch);

  /// Creates a hub.
  ///
  /// [transports] are bound on [start]; more can be added with [addTransport].
  /// [middleware] runs on every request (outermost first), after the hub's own
  /// error-mapping wrapper. [logger] defaults to a no-op.
  OmnyHub({
    List<Transport> transports = const [],
    List<Middleware> middleware = const [],
    this.router = const RuleRouter(),
    this.authenticator = const AnonymousAuthenticator(),
    this.authorizer = const AllowAllAuthorizer(),
    this.logger = const NoopLogger(),
    this.clock = const SystemClock(),
    this.tlsRenewalInterval = const Duration(hours: 12),
    IdGenerator? idGenerator,
  }) : _transports = List.of(transports),
       _middleware = List.of(middleware),
       idGenerator = idGenerator ?? RandomIdGenerator();

  /// The transports bound (or to be bound) by this hub.
  List<Transport> get transports => List.unmodifiable(_transports);

  /// The registered services.
  Iterable<Service> get services => _services.all;

  /// The current routing table.
  List<Route> get routes => List.unmodifiable(_routes);

  /// Whether [start] has been called (and [stop] has not).
  bool get isRunning => _running;

  /// The port of the first transport, or `null` if none. Convenience for the
  /// common single-transport case.
  int? get port => _transports.isEmpty ? null : _transports.first.port;

  /// Adds a [transport]. If the hub is already running, it is bound
  /// immediately.
  Future<void> addTransport(Transport transport) async {
    _transports.add(transport);
    if (_running) {
      await transport.bind(onRequest: _composed, onUpgrade: _handleUpgrade);
    }
  }

  /// Appends [middleware] to the pipeline. Must be called before [start].
  void use(Middleware middleware) {
    if (_running) {
      throw StateError('Cannot add middleware while the hub is running');
    }
    _middleware.add(middleware);
  }

  void _rebuildPipeline() {
    // ACME challenge middleware (if any TLS provider needs it) runs first, then
    // authentication, then user middleware. Challenges must be answered
    // unauthenticated on the plaintext transport.
    _composed = errorMapper(logger: logger)(
      composePipeline(_dispatch, [
        ..._challengeMiddlewares,
        _authMiddleware,
        ..._middleware,
      ]),
    );
  }

  Iterable<Middleware> get _challengeMiddlewares => _transports
      .whereType<HttpTransport>()
      .map((t) => t.tls?.challengeMiddleware)
      .whereType<Middleware>();

  /// Authenticates each request and attaches the principal before user
  /// middleware and routing run, so both can depend on auth state.
  Middleware get _authMiddleware =>
      (inner) => (request) async {
        request.principal = await authenticator.authenticate(request);
        return inner(request);
      };

  /// Registers [service] and adds a route to it.
  ///
  /// The route matches [when] if given, otherwise a [PathRule] on the service's
  /// [Service.mount]. [priority] orders it against other routes. If the hub is
  /// running, the service is started immediately. Throws if the name is already
  /// taken.
  Future<void> registerService(
    Service service, {
    RouteRule? when,
    int priority = 0,
  }) async {
    _services.register(service);
    _routes.add(
      Route(
        name: service.name,
        rule: when ?? PathRule(service.mount),
        target: service,
        priority: priority,
      ),
    );
    if (_running) await service.start();
  }

  /// Hosts [target] and routes requests matching [rule] to it — the building
  /// block for host/path-based gateways and reverse proxying.
  ///
  /// ```dart
  /// hub.route(HostRule('api.example.com'), proxyService);
  /// hub.route(PathRule('/drive'), driveProxy, priority: 10);
  /// ```
  Future<void> route(RouteRule rule, Service target, {int priority = 0}) =>
      registerService(target, when: rule, priority: priority);

  /// Removes and stops the service named [name] and drops its routes. Throws
  /// [NotFoundException] if absent.
  Future<void> unregisterService(String name) async {
    final service = _services.remove(name);
    _routes.removeWhere((r) => r.target.name == name);
    if (_running) await service.stop();
  }

  /// The service named [name], or `null`.
  Service? service(String name) => _services.get(name);

  /// Starts every service and binds every transport. Idempotent guard: throws
  /// [StateError] if already running.
  Future<void> start() async {
    if (_running) throw StateError('Hub is already running');
    for (final service in _services.all) {
      await service.start();
    }
    _rebuildPipeline();
    _running = true;

    // Bind plaintext transports first so ACME HTTP-01 challenges can be served
    // on :80 while secure transports provision their certificates.
    final secure = <Transport>[];
    for (final transport in _transports) {
      if (transport.isSecure) {
        secure.add(transport);
      } else {
        await transport.bind(onRequest: _composed, onUpgrade: _handleUpgrade);
      }
    }
    for (final transport in secure) {
      if (transport is HttpTransport) await transport.tls?.provision();
      await transport.bind(onRequest: _composed, onUpgrade: _handleUpgrade);
    }
    _startRenewalScheduler();

    logger.info(
      'OmnyHub started',
      context: {'transports': _transports.length, 'services': _services.length},
    );
  }

  /// Closes every transport and stops every service.
  Future<void> stop({bool force = true}) async {
    if (!_running) return;
    _running = false;
    _renewalTimer?.cancel();
    _renewalTimer = null;
    for (final transport in _transports) {
      await transport.close(force: force);
    }
    for (final service in _services.all) {
      await service.stop();
    }
    logger.info('OmnyHub stopped');
  }

  void _startRenewalScheduler() {
    if (tlsRenewalInterval <= Duration.zero) return;
    final anyHotReloadable = _transports.whereType<HttpTransport>().any(
      (t) => t.tls?.hotReloadable ?? false,
    );
    if (!anyHotReloadable) return;
    _renewalTimer = Timer.periodic(
      tlsRenewalInterval,
      (_) => unawaited(renewTls()),
    );
  }

  /// Checks each hot-reloadable TLS transport for certificate renewal, rebinding
  /// the listener when a certificate is refreshed. Runs automatically on the
  /// [tlsRenewalInterval]; also callable manually.
  Future<void> renewTls() async {
    for (final transport in _transports.whereType<HttpTransport>()) {
      final tls = transport.tls;
      if (tls == null || !tls.hotReloadable) continue;
      try {
        if (await tls.maybeRenew()) {
          await transport.rebind();
          logger.info(
            'TLS certificate renewed',
            context: {'port': transport.port},
          );
        }
      } on Object catch (e) {
        logger.error('TLS renewal failed', context: {'error': '$e'});
      }
    }
  }

  Future<HubResponse> _dispatch(HubRequest request) async {
    final context = RouteContext.fromRequest(request);
    final route = router.resolve(context, _routes);
    if (route == null) {
      throw RoutingException(message: 'No route handles ${request.path}');
    }
    if (!await authorizer.authorize(request.principal, context)) {
      throw const ForbiddenException();
    }
    return route.target.handle(request);
  }

  Future<void> _handleUpgrade(Connection connection, HubRequest request) async {
    // WebSocket upgrades bypass the HTTP middleware pipeline, so authenticate
    // and authorize here explicitly (fail-closed on rejection).
    try {
      request.principal = await authenticator.authenticate(request);
    } on UnauthorizedException {
      await connection.close(WsCloseCodes.unauthorized, 'Unauthorized');
      return;
    }
    final context = RouteContext.fromRequest(request);
    final route = router.resolve(context, _routes);
    if (route == null) {
      await connection.close(WsCloseCodes.notFound, 'No route');
      return;
    }
    if (!await authorizer.authorize(request.principal, context)) {
      await connection.close(WsCloseCodes.forbidden, 'Forbidden');
      return;
    }
    await route.target.handleConnection(connection, request);
  }
}
