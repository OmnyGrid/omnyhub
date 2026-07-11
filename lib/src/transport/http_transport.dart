import 'dart:async';
import 'dart:io';

import 'package:multi_domain_secure_server/multi_domain_secure_server.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';

import '../core/transport_protocol.dart';
import '../http/handler.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../shared/errors/hub_exception.dart';
import 'tls/tls_provider.dart';
import 'transport.dart';
import 'web_socket_connection.dart';

/// A [Transport] built on `shelf` + `shelf_web_socket`.
///
/// Serves plaintext HTTP (`http`/`ws`) or, with a [TlsProvider], TLS
/// (`https`/`wss`). WebSocket upgrades are handled on the same listener as
/// ordinary requests, so a single port carries both request/response services
/// and WebSocket services.
class HttpTransport implements Transport {
  @override
  final Object address;

  final int _requestedPort;

  /// The TLS material provider, or `null` for a plaintext listener.
  final TlsProvider? tls;

  final bool _secure;

  HttpServer? _server;
  MultiDomainSecureServer? _sniServer;
  HubRequestHandler? _onRequest;
  ConnectionHandler? _onUpgrade;

  HttpTransport._({
    required this.address,
    required int port,
    required bool secure,
    this.tls,
  }) : _requestedPort = port,
       _secure = secure;

  /// A plaintext HTTP/WS transport bound to [address]:[port]. Pass `port: 0`
  /// for an ephemeral port.
  factory HttpTransport.http({Object address = '0.0.0.0', required int port}) =>
      HttpTransport._(address: address, port: port, secure: false);

  /// A TLS HTTPS/WSS transport bound to [address]:[port], using [tls] for
  /// certificate material.
  factory HttpTransport.https({
    Object address = '0.0.0.0',
    required int port,
    required TlsProvider tls,
  }) => HttpTransport._(address: address, port: port, secure: true, tls: tls);

  @override
  TransportProtocol get protocol =>
      _secure ? TransportProtocol.https : TransportProtocol.http;

  @override
  bool get isSecure => _secure;

  @override
  bool get isBound => _server != null;

  @override
  int get port => _server?.port ?? _requestedPort;

  @override
  Future<void> bind({
    required HubRequestHandler onRequest,
    ConnectionHandler? onUpgrade,
  }) async {
    if (_server != null) {
      throw const TransportException('Transport is already bound');
    }
    _onRequest = onRequest;
    _onUpgrade = onUpgrade;

    final provider = tls;
    final SniTlsProvider? sni = (_secure && provider is SniTlsProvider)
        ? provider as SniTlsProvider
        : null;
    try {
      if (sni != null && sni.supportsSni) {
        await _bindSni(sni);
      } else {
        _server = await shelf_io.serve(
          _handle,
          address,
          _requestedPort,
          securityContext: _secure ? provider!.securityContext() : null,
          shared: true,
        );
      }
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('Failed to bind ${protocol.name}: $e');
    }
  }

  /// Binds an SNI-aware TLS listener that selects (and may provision on demand)
  /// a certificate per requested host via [SniTlsProvider.contextFor].
  Future<void> _bindSni(SniTlsProvider provider) async {
    final defaultContext = provider.defaultContext;
    final sniServer = await MultiDomainSecureServer.bind(
      address,
      _requestedPort,
      shared: true,
      // Require SNI only when there is no default certificate to fall back to.
      requiresHandshakesWithHostname: defaultContext == null,
      defaultSecureContext: defaultContext,
      securityContextResolver: provider.contextFor,
    );
    final httpServer = sniServer.asHttpServer();
    shelf_io.serveRequests(httpServer, _handle);
    _sniServer = sniServer;
    _server = httpServer;
  }

  /// Rebinds the listener with a freshly built [SecurityContext] (used when an
  /// ACME certificate is renewed). The previous listener is drained first.
  Future<void> rebind() async {
    final onRequest = _onRequest;
    if (onRequest == null) return;
    final onUpgrade = _onUpgrade;
    await close(force: true);
    await bind(onRequest: onRequest, onUpgrade: onUpgrade);
  }

  @override
  Future<void> close({bool force = false}) async {
    final server = _server;
    final sniServer = _sniServer;
    _server = null;
    _sniServer = null;
    if (server != null) await server.close(force: force);
    if (sniServer != null) await sniServer.close();
  }

  Future<shelf.Response> _handle(shelf.Request request) async {
    final isUpgrade = _isWebSocketUpgrade(request);
    final onUpgrade = _onUpgrade;

    if (isUpgrade && onUpgrade != null) {
      final hubRequest = _toHubRequest(request, upgrade: true);
      final wsHandler = webSocketHandler((channel, _) {
        onUpgrade(
          WebSocketConnection.fromChannel(
            channel,
            remoteAddress: hubRequest.remoteAddress,
          ),
          hubRequest,
        );
      });
      return await Future.sync(() => wsHandler(request));
    }

    final hubRequest = _toHubRequest(request, upgrade: false);
    try {
      final response = await _onRequest!(hubRequest);
      return _toShelfResponse(response);
    } on HubException catch (e) {
      return _toShelfResponse(HubResponse.error(e));
    } on Object catch (_) {
      return _toShelfResponse(
        HubResponse.error(const TransportException('Internal server error')),
      );
    }
  }

  HubRequest _toHubRequest(shelf.Request request, {required bool upgrade}) {
    final TransportProtocol protocol;
    if (upgrade) {
      protocol = _secure ? TransportProtocol.wss : TransportProtocol.ws;
    } else {
      protocol = _secure ? TransportProtocol.https : TransportProtocol.http;
    }
    return HubRequest(
      method: request.method,
      uri: request.requestedUri,
      protocol: protocol,
      headers: request.headers,
      remoteAddress: _remoteAddress(request),
      body: upgrade ? null : request.read(),
    );
  }

  shelf.Response _toShelfResponse(HubResponse response) => shelf.Response(
    response.statusCode,
    body: response.read(),
    headers: response.headers,
  );

  static bool _isWebSocketUpgrade(shelf.Request request) {
    final upgrade = request.headers['upgrade']?.toLowerCase();
    final connection = request.headers['connection']?.toLowerCase();
    return upgrade == 'websocket' && (connection?.contains('upgrade') ?? false);
  }

  static String? _remoteAddress(shelf.Request request) {
    final info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return null;
  }
}
