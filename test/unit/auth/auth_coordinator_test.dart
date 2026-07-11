import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

Route routeWith({Authenticator? authenticator}) => Route(
  name: 'r',
  rule: const AnyRule(),
  target: HandlerService(name: 'r', handler: (_) async => HubResponse.ok()),
  authenticator: authenticator,
);

HubRequest req({Principal? principal}) => HubRequest(
  method: 'GET',
  uri: Uri.parse('http://h/'),
  protocol: TransportProtocol.http,
  principal: principal,
);

void main() {
  group('DefaultAuthCoordinator', () {
    const AuthCoordinator coordinator = DefaultAuthCoordinator();

    test('delegates when the route has an authenticator', () async {
      final d = await coordinator.authenticate(
        req(),
        routeWith(authenticator: const AnonymousAuthenticator()),
      );
      expect(d, isA<Delegate>());
    });

    test('reflects a pre-set principal as Authenticated', () async {
      final p = Principal(id: 'u');
      final d = await coordinator.authenticate(req(principal: p), routeWith());
      expect(d, isA<Authenticated>());
      expect((d as Authenticated).principal, p);
    });

    test('anonymous when no route authenticator and no principal', () async {
      final d = await coordinator.authenticate(req(), routeWith());
      expect(d, isA<Anonymous>());
    });
  });

  group('CoordinatorFn', () {
    test('wraps a closure and can block', () async {
      final coordinator = CoordinatorFn((request, route) {
        if (request.header('x-bad') != null) {
          return const Blocked(TooManyRequestsException('nope'));
        }
        return const Anonymous();
      });
      expect(
        await coordinator.authenticate(req(), routeWith()),
        isA<Anonymous>(),
      );
      final blocked = await coordinator.authenticate(
        HubRequest(
          method: 'GET',
          uri: Uri.parse('http://h/'),
          protocol: TransportProtocol.http,
          headers: {'x-bad': '1'},
        ),
        routeWith(),
      );
      expect(blocked, isA<Blocked>());
      expect((blocked as Blocked).reason, isA<TooManyRequestsException>());
    });
  });

  test('TooManyRequestsException is 429', () {
    expect(const TooManyRequestsException().statusCode, 429);
    expect(const TooManyRequestsException().code, ErrorCodes.tooManyRequests);
  });
}
