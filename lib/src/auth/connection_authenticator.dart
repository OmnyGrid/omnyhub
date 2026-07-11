import '../core/handshake_connection.dart';
import '../core/principal.dart';
import '../http/hub_request.dart';

/// Authenticates a WebSocket connection with an **in-band handshake** after the
/// upgrade completes, when header-based [Authenticator] auth is not enough
/// (e.g. a challenge/response or signature exchange).
///
/// The hub invokes this before the service's `handleConnection`, passing a
/// [HandshakeConnection] whose [HandshakeConnection.receive] pulls the handshake
/// messages; whatever is not consumed is replayed to the service. Return the
/// [Principal] (attached to the request), or throw a `HubException` to reject —
/// the hub then closes the connection.
///
/// Configure it globally (`OmnyHub(connectionAuthenticator: ...)`) or per
/// service/route.
abstract interface class ConnectionAuthenticator {
  /// Runs the in-band handshake over [connection] for the upgrade [request].
  Future<Principal?> authenticate(
    HandshakeConnection connection,
    HubRequest request,
  );
}
