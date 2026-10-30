import 'dart:io';

import 'package:omnyhub/omnyhub.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// Stands in for shelf's lazy connection info, which throws a [StateError]
/// once the client has disconnected.
class _ConnectionInfo implements HttpConnectionInfo {
  _ConnectionInfo(this._address);

  final InternetAddress? _address;

  @override
  InternetAddress get remoteAddress =>
      _address ??
      (throw StateError(
        'HttpConnectionInfo is unavailable because the connection is closed.',
      ));

  @override
  int get remotePort => 0;

  @override
  int get localPort => 0;
}

shelf.Request req({Object? info}) => shelf.Request(
  'GET',
  Uri.parse('http://api.example.com/'),
  context: {'shelf.io.connection_info': ?info},
);

void main() {
  group('HttpTransport.remoteAddressOf', () {
    test('reads the address from the connection info', () {
      final info = _ConnectionInfo(InternetAddress.loopbackIPv4);
      expect(HttpTransport.remoteAddressOf(req(info: info)), '127.0.0.1');
    });

    test('is null without connection info', () {
      expect(HttpTransport.remoteAddressOf(req()), isNull);
    });

    test('is null, not an error, once the client has disconnected', () {
      final info = _ConnectionInfo(null);
      expect(HttpTransport.remoteAddressOf(req(info: info)), isNull);
    });
  });
}
