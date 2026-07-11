import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('Principal', () {
    test('role checks', () {
      final p = Principal(id: 'u1', roles: {'admin', 'ops'});
      expect(p.hasRole('admin'), isTrue);
      expect(p.hasRole('guest'), isFalse);
      expect(p.hasAllRoles(['admin', 'ops']), isTrue);
      expect(p.hasAllRoles(['admin', 'guest']), isFalse);
      expect(p.hasAnyRole(['guest', 'ops']), isTrue);
      expect(p.hasAnyRole(['guest']), isFalse);
    });

    test('equality is by id, name, roles and attributes', () {
      final a = Principal(
        id: 'u1',
        displayName: 'User One',
        roles: {'a', 'b'},
        attributes: {'team': 'core'},
      );
      final b = Principal(
        id: 'u1',
        displayName: 'User One',
        roles: {'b', 'a'},
        attributes: {'team': 'core'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(Principal(id: 'u2', roles: {'a', 'b'})));
      expect(a, isNot(Principal(id: 'u1', roles: {'a'})));
    });

    test('collections are unmodifiable', () {
      final p = Principal(id: 'u1', roles: {'a'});
      expect(() => p.roles.add('b'), throwsUnsupportedError);
      expect(() => p.attributes['x'] = 'y', throwsUnsupportedError);
    });

    test('toString is concise', () {
      final p = Principal(id: 'u1', roles: {'admin'});
      expect(p.toString(), 'Principal(u1, roles: admin)');
    });
  });
}
