import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

RouteContext get anyContext => RouteContext.fromRequest(
  HubRequest(
    method: 'GET',
    uri: Uri.parse('http://h/'),
    protocol: TransportProtocol.http,
  ),
);

void main() {
  final admin = Principal(id: 'a', roles: {'admin'});
  final user = Principal(id: 'u', roles: {'user'});

  test('AllowAll / DenyAll', () async {
    expect(
      await const AllowAllAuthorizer().authorize(null, anyContext),
      isTrue,
    );
    expect(
      await const DenyAllAuthorizer().authorize(admin, anyContext),
      isFalse,
    );
  });

  group('RoleBasedAuthorizer', () {
    test('requires authentication by default', () async {
      const authz = RoleBasedAuthorizer();
      expect(await authz.authorize(null, anyContext), isFalse);
      expect(await authz.authorize(user, anyContext), isTrue);
    });

    test('requires one of the roles', () async {
      const authz = RoleBasedAuthorizer(anyRoles: {'admin'});
      expect(await authz.authorize(admin, anyContext), isTrue);
      expect(await authz.authorize(user, anyContext), isFalse);
      expect(await authz.authorize(null, anyContext), isFalse);
    });

    test('can allow anonymous when not requiring auth', () async {
      const authz = RoleBasedAuthorizer(requireAuthenticated: false);
      expect(await authz.authorize(null, anyContext), isTrue);
    });
  });

  test('PredicateAuthorizer', () async {
    final authz = PredicateAuthorizer((p, _) async => p?.id == 'a');
    expect(await authz.authorize(admin, anyContext), isTrue);
    expect(await authz.authorize(user, anyContext), isFalse);
  });
}
