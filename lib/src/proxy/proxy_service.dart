import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/connection.dart';
import '../core/transport_protocol.dart';
import '../core/ws_close.dart';
import '../http/hub_request.dart';
import '../http/hub_response.dart';
import '../service/service.dart';
import '../shared/errors/hub_exception.dart';
import '../transport/web_socket_connection.dart';
import 'upstream.dart';

/// A [Service] that reverse-proxies requests to an [Upstream].
///
/// Forwards the full request (streaming the body), copies the response back
/// (streaming, so large payloads never buffer), injects the `X-Forwarded-*`
/// headers, strips hop-by-hop headers, and forwards WebSocket upgrades by
/// dialing the upstream and piping frames in both directions. Because it is an
/// ordinary [Service], it participates in the hub's routing, auth and pipeline
/// exactly like a local service — host-based and path-based gateways differ
/// only in the [RouteRule] used to reach it.
class ProxyService extends ServiceBase {
  /// The upstream target selector.
  final Upstream upstream;

  /// A path prefix removed from the request path before forwarding (e.g. strip
  /// `/api` so `/api/x` reaches the upstream as `/x`). `null` forwards the path
  /// unchanged.
  final String? stripPrefix;

  /// Whether to forward WebSocket upgrade requests to the upstream.
  final bool forwardWebSocket;

  final http.Client _client;
  final bool _ownsClient;

  /// Hop-by-hop headers that must not be forwarded (RFC 7230 §6.1).
  static const _hopByHop = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailers',
    'transfer-encoding',
    'upgrade',
  };

  /// Creates a reverse proxy to [upstream].
  ///
  /// Provide a [client] to share an HTTP client (it will not be closed on
  /// [stop]); otherwise one is created and owned. [mount] is the local path the
  /// proxy is hosted at when registered via `registerService`.
  ProxyService(
    this.upstream, {
    required super.name,
    super.mount,
    this.stripPrefix,
    this.forwardWebSocket = true,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  @override
  Future<HubResponse> handle(HubRequest request) async {
    final target = _targetUri(request, upstream.select(request));
    final outgoing = http.StreamedRequest(request.method, target)
      ..followRedirects = false;
    _copyRequestHeaders(request, outgoing.headers, target);

    // Stream the request body up to the upstream.
    unawaited(
      outgoing.sink.addStream(request.read()).whenComplete(outgoing.sink.close),
    );

    final http.StreamedResponse response;
    try {
      response = await _client.send(outgoing);
    } on Object catch (e) {
      throw ProxyException(message: 'Upstream request failed: $e');
    }

    return HubResponse.stream(
      response.stream,
      statusCode: response.statusCode,
      headers: _filterResponseHeaders(response.headers),
    );
  }

  @override
  FutureOr<void> handleConnection(
    Connection connection,
    HubRequest request,
  ) async {
    if (!forwardWebSocket) {
      await connection.close(WsCloseCodes.unsupported, 'WebSocket not proxied');
      return;
    }

    final target = _webSocketTarget(request, upstream.select(request));
    final WebSocketConnection upstreamConn;
    try {
      upstreamConn = await WebSocketConnection.connect(
        target,
        headers: _webSocketForwardHeaders(request),
      );
    } on Object {
      await connection.close(WsCloseCodes.badGateway, 'Upstream unavailable');
      return;
    }

    // Pipe frames both ways until either side closes.
    final downToUp = connection.incoming.listen(
      upstreamConn.send,
      onDone: () => unawaited(upstreamConn.close()),
      onError: (_) => unawaited(upstreamConn.close()),
    );
    final upToDown = upstreamConn.incoming.listen(
      connection.send,
      onDone: () => unawaited(connection.close()),
      onError: (_) => unawaited(connection.close()),
    );

    await Future.any([connection.done, upstreamConn.done]);
    await connection.close();
    await upstreamConn.close();
    await downToUp.cancel();
    await upToDown.cancel();
  }

  @override
  Future<void> stop() async {
    if (_ownsClient) _client.close();
  }

  Uri _targetUri(HubRequest request, Uri base) {
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    final path = '$basePath${_forwardPath(request)}';
    return base.replace(
      path: path.isEmpty ? '/' : path,
      query: request.uri.hasQuery ? request.uri.query : null,
    );
  }

  Uri _webSocketTarget(HubRequest request, Uri base) {
    final scheme = switch (base.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };
    return _targetUri(request, base).replace(scheme: scheme);
  }

  String _forwardPath(HubRequest request) {
    var path = request.path;
    final strip = stripPrefix;
    if (strip != null && strip.isNotEmpty && path.startsWith(strip)) {
      path = path.substring(strip.length);
      if (!path.startsWith('/')) path = '/$path';
    }
    return path;
  }

  void _copyRequestHeaders(
    HubRequest request,
    Map<String, String> out,
    Uri target,
  ) {
    for (final entry in request.headers.entries) {
      if (_hopByHop.contains(entry.key) ||
          entry.key == 'host' ||
          entry.key == 'content-length') {
        continue;
      }
      out[entry.key] = entry.value;
    }
    out['host'] = target.hasPort
        ? '${target.host}:${target.port}'
        : target.host;
    _appendForwarded(request, out);
  }

  void _appendForwarded(HubRequest request, Map<String, String> out) {
    final remote = request.remoteAddress;
    if (remote != null) {
      final existing = out['x-forwarded-for'];
      out['x-forwarded-for'] = existing == null ? remote : '$existing, $remote';
    }
    out['x-forwarded-proto'] = request.protocol.isSecure
        ? 'https'
        : (request.protocol == TransportProtocol.ws ? 'ws' : 'http');
    out['x-forwarded-host'] = request.host;
  }

  Map<String, String> _webSocketForwardHeaders(HubRequest request) {
    final out = <String, String>{};
    const wsManaged = {
      'host',
      'connection',
      'upgrade',
      'sec-websocket-key',
      'sec-websocket-version',
      'sec-websocket-extensions',
      'sec-websocket-accept',
      'sec-websocket-protocol',
    };
    for (final entry in request.headers.entries) {
      if (_hopByHop.contains(entry.key) || wsManaged.contains(entry.key)) {
        continue;
      }
      out[entry.key] = entry.value;
    }
    _appendForwarded(request, out);
    return out;
  }

  Map<String, String> _filterResponseHeaders(Map<String, String> headers) {
    final out = <String, String>{};
    for (final entry in headers.entries) {
      final key = entry.key.toLowerCase();
      if (_hopByHop.contains(key)) continue;
      out[key] = entry.value;
    }
    return out;
  }
}
