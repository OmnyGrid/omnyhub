import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

import '../../support/loopback_connection.dart';

HubRequest get req => HubRequest(
  method: 'GET',
  uri: Uri.parse('http://h/ws'),
  protocol: TransportProtocol.ws,
);

void main() {
  group('HandlerService.handlesWebSocket', () {
    test('is false without an onConnection handler', () {
      final service = HandlerService(
        name: 's',
        handler: (_) async => HubResponse.ok(),
      );
      expect(service.handlesWebSocket, isFalse);
    });

    test('is true when an onConnection handler is provided', () {
      final service = HandlerService(
        name: 's',
        handler: (_) async => HubResponse.ok(),
        onConnection: (_, _) {},
      );
      expect(service.handlesWebSocket, isTrue);
    });
  });

  group('HandlerService WebSocket handling', () {
    test('invokes onConnection for an upgrade', () async {
      Connection? seen;
      final service = HandlerService(
        name: 's',
        handler: (_) async => HubResponse.ok(),
        onConnection: (conn, _) => seen = conn,
      );
      final conn = LoopbackConnection();
      await service.handleConnection(conn, req);
      expect(seen, same(conn));
    });

    test(
      'rejects an upgrade with the unsupported close code when no handler',
      () async {
        final service = HandlerService(
          name: 's',
          handler: (_) async => HubResponse.ok(),
        );
        final conn = LoopbackConnection();
        await service.handleConnection(conn, req);
        expect(conn.isOpen, isFalse); // closed by ServiceBase default
      },
    );
  });
}
