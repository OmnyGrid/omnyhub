import 'dart:convert';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('HubRequest', () {
    test('lower-cases headers, upper-cases method, derives path/host', () {
      final req = HubRequest(
        method: 'get',
        uri: Uri.parse('http://api.example.com/v1/items?a=1'),
        protocol: TransportProtocol.http,
        headers: {'Content-Type': 'text/plain', 'X-Trace': 'abc'},
      );
      expect(req.method, 'GET');
      expect(req.path, '/v1/items');
      expect(req.host, 'api.example.com');
      expect(req.header('content-type'), 'text/plain');
      expect(req.header('X-TRACE'), 'abc');
    });

    test('detects WebSocket upgrade requests', () {
      final ws = HubRequest(
        method: 'GET',
        uri: Uri.parse('http://h/ws'),
        protocol: TransportProtocol.ws,
        headers: {'upgrade': 'websocket', 'connection': 'Upgrade'},
      );
      expect(ws.isWebSocketUpgrade, isTrue);

      final plain = HubRequest(
        method: 'GET',
        uri: Uri.parse('http://h/'),
        protocol: TransportProtocol.http,
      );
      expect(plain.isWebSocketUpgrade, isFalse);
    });

    test('reads body once and rejects a second read', () async {
      final req = HubRequest(
        method: 'POST',
        uri: Uri.parse('http://h/'),
        protocol: TransportProtocol.http,
        body: Stream.value(utf8.encode('hi')),
      );
      expect(await req.readAsString(), 'hi');
      expect(req.read, throwsStateError);
    });

    test('isSecure follows the protocol', () {
      HubRequest r(TransportProtocol p) =>
          HubRequest(method: 'GET', uri: Uri.parse('http://h/'), protocol: p);
      expect(r(TransportProtocol.https).isSecure, isTrue);
      expect(r(TransportProtocol.wss).isSecure, isTrue);
      expect(r(TransportProtocol.http).isSecure, isFalse);
    });
  });

  group('HubResponse', () {
    test('text sets content-type and status', () async {
      final res = HubResponse.text('hello');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'text/plain; charset=utf-8');
      expect(await res.readAsString(), 'hello');
    });

    test('json encodes data', () async {
      final res = HubResponse.json({'a': 1}, statusCode: 201);
      expect(res.statusCode, 201);
      expect(res.headers['content-type'], 'application/json; charset=utf-8');
      expect(jsonDecode(await res.readAsString()), {'a': 1});
    });

    test('ok convenience covers null/string/object', () async {
      expect(HubResponse.ok().statusCode, 204);
      expect(await HubResponse.ok('x').readAsString(), 'x');
      final j = HubResponse.ok({'k': 'v'});
      expect(j.headers['content-type'], contains('application/json'));
    });

    test('error renders the exception envelope with its status', () async {
      final res = HubResponse.error(const ForbiddenException('no'));
      expect(res.statusCode, 403);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['error'], {'code': ErrorCodes.forbidden, 'message': 'no'});
    });

    test('bytes and stream bodies round-trip', () async {
      expect(await HubResponse.bytes([1, 2, 3]).readBytes(), [1, 2, 3]);
      final streamed = HubResponse.stream(
        Stream.fromIterable([
          [1],
          [2, 3],
        ]),
      );
      expect(await streamed.readBytes(), [1, 2, 3]);
    });
  });

  group('TransportProtocol', () {
    test('flags and secure mapping', () {
      expect(TransportProtocol.https.isSecure, isTrue);
      expect(TransportProtocol.ws.isWebSocket, isTrue);
      expect(TransportProtocol.http.secure, TransportProtocol.https);
      expect(TransportProtocol.ws.secure, TransportProtocol.wss);
      expect(TransportProtocol.wss.secure, TransportProtocol.wss);
    });
  });
}
