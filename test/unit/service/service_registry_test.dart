import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

HandlerService svc(String name, String mount) => HandlerService(
  name: name,
  mount: mount,
  handler: (_) async => HubResponse.text(name),
);

void main() {
  group('ServiceRegistry.normalizeMount', () {
    test('canonicalises mounts', () {
      expect(ServiceRegistry.normalizeMount(''), '/');
      expect(ServiceRegistry.normalizeMount('/'), '/');
      expect(ServiceRegistry.normalizeMount('api'), '/api');
      expect(ServiceRegistry.normalizeMount('/api/'), '/api');
      expect(ServiceRegistry.normalizeMount('/api/v1//'), '/api/v1');
    });
  });

  group('ServiceRegistry', () {
    test('register rejects duplicate names', () {
      final reg = ServiceRegistry()..register(svc('a', '/a'));
      expect(
        () => reg.register(svc('a', '/b')),
        throwsA(isA<ValidationException>()),
      );
    });

    test('remove returns the service or throws NotFound', () {
      final reg = ServiceRegistry()..register(svc('a', '/a'));
      expect(reg.remove('a').name, 'a');
      expect(reg.contains('a'), isFalse);
      expect(() => reg.remove('a'), throwsA(isA<NotFoundException>()));
    });

    test('resolve picks the longest matching mount prefix', () {
      final reg = ServiceRegistry()
        ..register(svc('root', '/'))
        ..register(svc('api', '/api'))
        ..register(svc('apiV1', '/api/v1'));

      expect(reg.resolve('/api/v1/items')?.name, 'apiV1');
      expect(reg.resolve('/api/other')?.name, 'api');
      expect(reg.resolve('/api')?.name, 'api');
      expect(reg.resolve('/anything')?.name, 'root');
    });

    test('resolve returns null when nothing matches and no root mount', () {
      final reg = ServiceRegistry()..register(svc('api', '/api'));
      expect(reg.resolve('/metrics'), isNull);
      // Prefix must be path-segment aligned: /apixyz must not match /api.
      expect(reg.resolve('/apixyz'), isNull);
    });
  });
}
