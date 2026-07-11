import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

RouteContext ctx({
  String method = 'GET',
  String url = 'http://api.example.com/api/items',
  TransportProtocol protocol = TransportProtocol.https,
  Map<String, String> headers = const {},
  Principal? principal,
}) {
  return RouteContext.fromRequest(
    HubRequest(
      method: method,
      uri: Uri.parse(url),
      protocol: protocol,
      headers: headers,
      principal: principal,
    ),
  );
}

void main() {
  group('RouteContext host splitting', () {
    test('splits domain and subdomain', () {
      final c = ctx(url: 'http://api.example.com/');
      expect(c.domain, 'example.com');
      expect(c.subdomain, 'api');
    });

    test('multi-label subdomain', () {
      final c = ctx(url: 'http://a.b.example.com/');
      expect(c.domain, 'example.com');
      expect(c.subdomain, 'a.b');
    });

    test('bare domain has no subdomain', () {
      final c = ctx(url: 'http://example.com/');
      expect(c.domain, 'example.com');
      expect(c.subdomain, '');
    });

    test('IP addresses are treated as the whole host', () {
      final c = ctx(url: 'http://127.0.0.1:8080/');
      expect(c.domain, '127.0.0.1');
      expect(c.subdomain, '');
    });
  });

  group('PathRule', () {
    test('segment-aligned prefix and exact', () {
      expect(PathRule('/api').matches(ctx(url: 'http://h/api/x')), isTrue);
      expect(PathRule('/api').matches(ctx(url: 'http://h/api')), isTrue);
      expect(PathRule('/api').matches(ctx(url: 'http://h/apix')), isFalse);
      expect(
        PathRule('/api', exact: true).matches(ctx(url: 'http://h/api/x')),
        isFalse,
      );
      expect(PathRule('/').matches(ctx(url: 'http://h/anything')), isTrue);
    });

    test('longer prefix is more specific', () {
      expect(
        PathRule('/api/v1').specificity,
        greaterThan(PathRule('/api').specificity),
      );
    });
  });

  group('HostRule / DomainRule / SubdomainRule', () {
    test('exact and wildcard host', () {
      expect(HostRule('api.example.com').matches(ctx()), isTrue);
      expect(HostRule('other.example.com').matches(ctx()), isFalse);
      expect(HostRule('*.example.com').matches(ctx()), isTrue);
      expect(
        HostRule('*.example.com').matches(ctx(url: 'http://a.b.example.com/')),
        isTrue,
      );
    });

    test('domain and subdomain', () {
      expect(DomainRule('example.com').matches(ctx()), isTrue);
      expect(SubdomainRule('api').matches(ctx()), isTrue);
      expect(SubdomainRule('www').matches(ctx()), isFalse);
    });
  });

  group('HeaderRule / ProtocolRule / MethodRule', () {
    test('header presence, equals, contains', () {
      final c = ctx(headers: {'x-env': 'Production'});
      expect(const HeaderRule('x-env').matches(c), isTrue);
      expect(const HeaderRule('x-missing').matches(c), isFalse);
      expect(
        const HeaderRule('x-env', equals: 'production').matches(c),
        isTrue,
      );
      expect(const HeaderRule('x-env', contains: 'duct').matches(c), isTrue);
    });

    test('protocol and method', () {
      expect(ProtocolRule.secure().matches(ctx()), isTrue);
      expect(
        ProtocolRule.secure().matches(ctx(protocol: TransportProtocol.http)),
        isFalse,
      );
      expect(MethodRule(['post']).matches(ctx(method: 'POST')), isTrue);
      expect(MethodRule(['post']).matches(ctx(method: 'GET')), isFalse);
    });
  });

  group('AuthStateRule', () {
    final admin = Principal(id: 'u', roles: {'admin'});
    test('authenticated / anonymous', () {
      expect(
        const AuthStateRule.authenticated().matches(ctx(principal: admin)),
        isTrue,
      );
      expect(const AuthStateRule.authenticated().matches(ctx()), isFalse);
      expect(const AuthStateRule.anonymous().matches(ctx()), isTrue);
    });

    test('role requirements', () {
      expect(
        AuthStateRule.hasRole('admin').matches(ctx(principal: admin)),
        isTrue,
      );
      expect(
        AuthStateRule.hasRole('root').matches(ctx(principal: admin)),
        isFalse,
      );
      expect(
        AuthStateRule.hasAnyRole({
          'root',
          'admin',
        }).matches(ctx(principal: admin)),
        isTrue,
      );
    });
  });

  group('combinators', () {
    test('and / or / not via operators', () {
      final rule = PathRule('/api') & HostRule('api.example.com');
      expect(rule.matches(ctx()), isTrue);
      expect(rule.matches(ctx(url: 'http://api.example.com/other')), isFalse);

      final either = PathRule('/x') | PathRule('/api');
      expect(either.matches(ctx()), isTrue);

      expect((~PathRule('/x')).matches(ctx()), isTrue);
    });

    test('predicate and any', () {
      expect(PredicateRule((c) => c.method == 'GET').matches(ctx()), isTrue);
      expect(const AnyRule().matches(ctx()), isTrue);
      expect(const AnyRule().specificity, 0);
    });
  });
}
