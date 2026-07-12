import '../shared/errors/hub_exception.dart';

/// WebSocket close codes used by the framework.
///
/// The underlying WebSocket library only permits application close codes of
/// `1000` (normal) or the range `3000`–`4999`, so OmnyHub maps its rejection
/// reasons onto `44xx` codes that echo the corresponding HTTP status.
class WsCloseCodes {
  /// Normal closure.
  static const int normal = 1000;

  /// The upgrade request was not authenticated (echoes HTTP 401).
  static const int unauthorized = 4401;

  /// The caller is authenticated but not permitted (echoes HTTP 403).
  static const int forbidden = 4403;

  /// No route matched the upgrade request (echoes HTTP 404).
  static const int notFound = 4404;

  /// The matched service does not support WebSocket connections.
  static const int unsupported = 4400;

  /// A reverse-proxy upstream was unreachable or failed (echoes HTTP 502).
  static const int badGateway = 4502;

  /// The close code that echoes [e]'s HTTP status.
  ///
  /// The single mapping used wherever a [HubException] has to reject a
  /// connection rather than a request — the hub's upgrade path and the node
  /// gateway's registration path. Statuses with no dedicated code fall back to
  /// [unauthorized], since every unmapped rejection so far is a refusal to
  /// serve the peer.
  static int forException(HubException e) => switch (e.statusCode) {
    401 => unauthorized,
    403 => forbidden,
    404 => notFound,
    502 || 503 || 504 => badGateway,
    _ => unauthorized,
  };

  const WsCloseCodes._();
}
