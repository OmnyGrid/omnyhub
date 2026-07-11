import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

HubRequest get req => HubRequest(
  method: 'GET',
  uri: Uri.parse('http://h/'),
  protocol: TransportProtocol.http,
);

void main() {
  test('SingleUpstream always returns its base', () {
    final u = Upstream.uri('http://localhost:8080');
    expect(u.select(req), Uri.parse('http://localhost:8080'));
    expect(u.select(req), Uri.parse('http://localhost:8080'));
  });

  test('RoundRobinUpstream cycles through bases', () {
    final u = Upstream.roundRobin(['http://a:1', 'http://b:2', 'http://c:3']);
    expect(u.select(req).host, 'a');
    expect(u.select(req).host, 'b');
    expect(u.select(req).host, 'c');
    expect(u.select(req).host, 'a'); // wraps around
  });

  test('empty round-robin pool is rejected', () {
    expect(() => RoundRobinUpstream([]), throwsA(isA<AssertionError>()));
  });
}
