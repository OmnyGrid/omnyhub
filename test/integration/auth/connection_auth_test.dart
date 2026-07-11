@TestOn('vm')
library;

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// An in-band handshake authenticator: expects the first frame to be a bearer
/// token `auth:<token>`, replies `ok`/`no`, and authenticates known tokens.
class HandshakeAuth implements ConnectionAuthenticator {
  final Map<String, Principal> tokens;
  HandshakeAuth(this.tokens);

  @override
  Future<Principal?> authenticate(
    HandshakeConnection connection,
    HubRequest request,
  ) async {
    final first = await connection.receive(timeout: const Duration(seconds: 5));
    final data = first is TextMessage ? first.data : '';
    if (!data.startsWith('auth:')) {
      throw const UnauthorizedException('handshake required');
    }
    final principal = tokens[data.substring(5)];
    if (principal == null) {
      throw const UnauthorizedException('bad token');
    }
    connection.send(const TextMessage('ok'));
    return principal;
  }
}

void main() {
  late OmnyHub hub;

  setUp(() async {
    hub = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await hub.registerService(
      HandlerService(
        name: 'ws',
        mount: '/ws',
        handler: (_) async => HubResponse.ok(),
        onConnection: (conn, req) {
          // After the handshake, echo subsequent frames, prefixing with the
          // authenticated principal (proves the buffered hand-off + identity).
          conn.incoming.listen((m) {
            if (m is TextMessage) {
              conn.send(TextMessage('${req.principal?.id}:${m.data}'));
            }
          });
        },
      ),
      connectionAuthenticator: HandshakeAuth({'good': Principal(id: 'worker')}),
    );
    await hub.start();
  });

  tearDown(() => hub.stop());

  test('in-band handshake authenticates then the service serves', () async {
    final conn = await WebSocketConnection.connect(
      Uri.parse('ws://127.0.0.1:${hub.port}/ws'),
    );
    final incoming = <Message>[];
    conn.incoming.listen(incoming.add);

    conn.send(const TextMessage('auth:good')); // handshake frame
    await _until(() => incoming.contains(const TextMessage('ok')));

    conn.send(const TextMessage('hello')); // served frame (post-handshake)
    await _until(() => incoming.contains(const TextMessage('worker:hello')));

    await conn.close();
  });

  test('a bad handshake token closes the connection', () async {
    final conn = await WebSocketConnection.connect(
      Uri.parse('ws://127.0.0.1:${hub.port}/ws'),
    );
    final messages = <Message>[];
    conn.incoming.listen(messages.add);
    conn.send(const TextMessage('auth:wrong'));
    await conn.done.timeout(const Duration(seconds: 5));
    expect(messages, isEmpty);
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!condition()) throw StateError('condition not met before timeout');
}
