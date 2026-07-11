/// The wire protocol a request or connection arrived on.
///
/// Used by transports to tag inbound traffic and by routing rules
/// (`ProtocolRule`) to match on it.
enum TransportProtocol {
  /// Plaintext HTTP.
  http,

  /// HTTP over TLS.
  https,

  /// Plaintext WebSocket.
  ws,

  /// WebSocket over TLS.
  wss;

  /// Whether this protocol is carried over TLS (`https`/`wss`).
  bool get isSecure => this == https || this == wss;

  /// Whether this protocol is a WebSocket (`ws`/`wss`).
  bool get isWebSocket => this == ws || this == wss;

  /// The URI scheme for this protocol (equals the enum name).
  String get scheme => name;

  /// The secure counterpart of an insecure protocol (and vice-versa maps to
  /// itself when already secure).
  TransportProtocol get secure => switch (this) {
    http => https,
    ws => wss,
    _ => this,
  };
}
