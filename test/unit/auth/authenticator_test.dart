import 'dart:convert';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

HubRequest reqWith(String? authorization) => HubRequest(
  method: 'GET',
  uri: Uri.parse('http://h/'),
  protocol: TransportProtocol.http,
  headers: {'authorization': ?authorization},
);

void main() {
  group('AnonymousAuthenticator', () {
    test('always anonymous', () async {
      expect(
        await const AnonymousAuthenticator().authenticate(reqWith(null)),
        isNull,
      );
    });
  });

  group('BearerTokenAuthenticator', () {
    final auth = BearerTokenAuthenticator({
      't0k3n': Principal(id: 'u1', roles: {'admin'}),
    });

    test('no header is anonymous', () async {
      expect(await auth.authenticate(reqWith(null)), isNull);
    });

    test('non-bearer scheme is anonymous', () async {
      expect(await auth.authenticate(reqWith('Basic abc')), isNull);
    });

    test('valid token yields the principal', () async {
      final p = await auth.authenticate(reqWith('Bearer t0k3n'));
      expect(p?.id, 'u1');
      expect(p?.hasRole('admin'), isTrue);
    });

    test('invalid token throws Unauthorized', () {
      expect(
        () => auth.authenticate(reqWith('Bearer nope')),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('resolver form', () async {
      final a = BearerTokenAuthenticator.resolver(
        (t) async => t == 'x' ? Principal(id: 'x') : null,
      );
      expect((await a.authenticate(reqWith('Bearer x')))?.id, 'x');
    });
  });

  group('BasicAuthAuthenticator', () {
    final auth = BasicAuthAuthenticator({
      'alice': 'secret',
    }, roles: (u) => {'user'});

    String basic(String user, String pass) =>
        'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

    test('valid credentials', () async {
      final p = await auth.authenticate(reqWith(basic('alice', 'secret')));
      expect(p?.id, 'alice');
      expect(p?.hasRole('user'), isTrue);
    });

    test('wrong password throws Unauthorized', () {
      expect(
        () => auth.authenticate(reqWith(basic('alice', 'wrong'))),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('malformed header throws Unauthorized', () {
      expect(
        () => auth.authenticate(reqWith('Basic !!!not-base64!!!')),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('no header is anonymous', () async {
      expect(await auth.authenticate(reqWith(null)), isNull);
    });
  });

  group('CompositeAuthenticator', () {
    test('returns first principal', () async {
      final composite = CompositeAuthenticator([
        const AnonymousAuthenticator(),
        BearerTokenAuthenticator({'t': Principal(id: 'z')}),
      ]);
      expect((await composite.authenticate(reqWith('Bearer t')))?.id, 'z');
    });

    test('propagates Unauthorized when nothing else matches', () {
      final composite = CompositeAuthenticator([
        BearerTokenAuthenticator({'good': Principal(id: 'g')}),
      ]);
      expect(
        () => composite.authenticate(reqWith('Bearer bad')),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('anonymous when no authenticator matches or fails', () async {
      final composite = CompositeAuthenticator([
        BearerTokenAuthenticator({'good': Principal(id: 'g')}),
      ]);
      expect(await composite.authenticate(reqWith(null)), isNull);
    });
  });
}
