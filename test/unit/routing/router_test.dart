import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

Route r(String name, RouteRule rule, {int priority = 0}) => Route(
  name: name,
  rule: rule,
  priority: priority,
  target: HandlerService(name: name, handler: (_) async => HubResponse.ok()),
);

RouteContext context(String url) => RouteContext.fromRequest(
  HubRequest(
    method: 'GET',
    uri: Uri.parse(url),
    protocol: TransportProtocol.https,
  ),
);

void main() {
  group('RuleRouter', () {
    const router = RuleRouter();

    test('returns null when nothing matches', () {
      expect(
        router.resolve(context('http://h/x'), [r('api', PathRule('/api'))]),
        isNull,
      );
    });

    test('prefers higher priority', () {
      final routes = [
        r('low', const AnyRule()),
        r('high', const AnyRule(), priority: 10),
      ];
      expect(router.resolve(context('http://h/'), routes)?.name, 'high');
    });

    test('breaks priority ties by specificity (longest prefix)', () {
      final routes = [
        r('root', PathRule('/')),
        r('api', PathRule('/api')),
        r('apiV1', PathRule('/api/v1')),
      ];
      expect(
        router.resolve(context('http://h/api/v1/x'), routes)?.name,
        'apiV1',
      );
      expect(router.resolve(context('http://h/api/z'), routes)?.name, 'api');
      expect(router.resolve(context('http://h/other'), routes)?.name, 'root');
    });

    test('registration order breaks exact ties', () {
      final routes = [
        r('first', const AnyRule()),
        r('second', const AnyRule()),
      ];
      expect(router.resolve(context('http://h/'), routes)?.name, 'first');
    });
  });

  group('custom Router', () {
    test('a custom strategy can override selection', () {
      final router = _LastMatchRouter();
      final routes = [r('a', const AnyRule()), r('b', const AnyRule())];
      expect(router.resolve(context('http://h/'), routes)?.name, 'b');
    });
  });
}

/// A custom router that returns the LAST matching route (proving strategies are
/// pluggable).
class _LastMatchRouter implements Router {
  @override
  Route? resolve(RouteContext context, List<Route> routes) {
    Route? match;
    for (final route in routes) {
      if (route.rule.matches(context)) match = route;
    }
    return match;
  }
}
