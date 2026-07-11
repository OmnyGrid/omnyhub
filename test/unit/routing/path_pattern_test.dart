import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('PathPattern', () {
    test('captures single segments', () {
      final p = PathPattern('/drives/<endpoint>/<name>');
      expect(p.match('/drives/laptop/docs'), {
        'endpoint': 'laptop',
        'name': 'docs',
      });
      expect(p.parameters, ['endpoint', 'name']);
    });

    test('does not match when a segment is missing or extra', () {
      final p = PathPattern('/drives/<endpoint>/<name>');
      expect(p.match('/drives/laptop'), isNull);
      expect(p.match('/drives/laptop/docs/extra'), isNull);
    });

    test('tail parameter captures the remainder including slashes', () {
      final p = PathPattern('/drives/<endpoint>/<name>/files/<path|.*>');
      expect(p.match('/drives/laptop/docs/files/a/b/c.txt'), {
        'endpoint': 'laptop',
        'name': 'docs',
        'path': 'a/b/c.txt',
      });
      // Empty tail is allowed.
      expect(p.match('/drives/laptop/docs/files/')?['path'], '');
    });

    test('literal segments must match exactly', () {
      final p = PathPattern('/drives/<endpoint>/<name>/files/<path|.*>');
      expect(p.match('/drives/laptop/docs/manifest'), isNull);
    });

    test('trailing slashes are normalised', () {
      final p = PathPattern('/api/<id>');
      expect(p.match('/api/7/'), {'id': '7'});
      expect(p.matches('/api/7'), isTrue);
    });

    test('custom regex constraint', () {
      final p = PathPattern(r'/n/<id|\d+>');
      expect(p.match('/n/42'), {'id': '42'});
      expect(p.match('/n/abc'), isNull);
    });

    test('a non-final tail parameter is rejected', () {
      expect(() => PathPattern('/a/<x|.*>/b'), throwsA(isA<ArgumentError>()));
    });
  });
}
