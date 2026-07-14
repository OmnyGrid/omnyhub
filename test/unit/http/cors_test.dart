import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

const String _app = 'https://app.example.com';

HubRequest req(
  String method, {
  String path = '/api/thing',
  Map<String, String> headers = const {},
}) => HubRequest(
  method: method,
  uri: Uri.parse('http://hub$path'),
  protocol: TransportProtocol.http,
  headers: headers,
);

HubRequest preflight({
  String origin = _app,
  String requestMethod = 'POST',
  Map<String, String> extra = const {},
}) => req(
  'OPTIONS',
  headers: {
    'origin': origin,
    'access-control-request-method': requestMethod,
    ...extra,
  },
);

void main() {
  group('cors preflight', () {
    test('is answered with a 204 and never reaches the handler', () async {
      var reached = false;
      final handler = cors(allowedOrigins: [_app])((request) async {
        reached = true;
        return HubResponse.text('handler');
      });

      final res = await handler(preflight());

      expect(res.statusCode, 204);
      expect(
        reached,
        isFalse,
        reason: 'routing must never see a preflight — it would 405/404 it',
      );
      expect(res.headers['access-control-allow-origin'], _app);
      expect(res.headers['access-control-allow-methods'], contains('POST'));
      expect(res.headers['access-control-max-age'], '86400');
      expect(res.headers['vary'], contains('Origin'));
    });

    test('allows the headers the omny APIs actually send', () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async => HubResponse.text('x'),
      );
      final allowed = (await handler(
        preflight(),
      )).headers['access-control-allow-headers']!;

      expect(allowed, contains('authorization'));
      expect(allowed, contains('x-omny-principal'));
      expect(allowed, contains('content-type'));
    });

    test('reflectRequestHeaders echoes what the browser asked for', () async {
      final handler = cors(allowedOrigins: [_app], reflectRequestHeaders: true)(
        (_) async => HubResponse.text('x'),
      );

      final res = await handler(
        preflight(extra: {'access-control-request-headers': 'x-custom, x-two'}),
      );
      expect(res.headers['access-control-allow-headers'], 'x-custom, x-two');
    });

    test(
      'a disallowed origin gets no allow-origin, and still no handler',
      () async {
        var reached = false;
        final handler = cors(allowedOrigins: [_app])((request) async {
          reached = true;
          return HubResponse.text('handler');
        });

        final res = await handler(
          preflight(origin: 'https://evil.example.com'),
        );

        expect(res.statusCode, 204);
        expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
        expect(reached, isFalse);
      },
    );

    test('a bare OPTIONS is a real request and reaches the handler', () async {
      var reached = false;
      final handler = cors(allowedOrigins: [_app])((request) async {
        reached = true;
        return HubResponse.text('handler');
      });

      // No access-control-request-method → not a preflight.
      await handler(req('OPTIONS', headers: {'origin': _app}));
      expect(reached, isTrue);
    });
  });

  group('cors actual requests', () {
    test('stamps allow-origin and preserves the response', () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async => HubResponse.text('body', headers: {'x-kept': '1'}),
      );

      final res = await handler(req('GET', headers: {'origin': _app}));

      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'body');
      expect(res.headers['x-kept'], '1');
      expect(res.headers['access-control-allow-origin'], _app);
      expect(res.headers['vary'], 'Origin');
    });

    test('a request with no Origin is passed through untouched', () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async => HubResponse.text('body'),
      );

      final res = await handler(req('GET'));

      expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
      expect(
        res.headers.containsKey('vary'),
        isFalse,
        reason: 'a non-browser caller must see exactly what it sees today',
      );
    });

    test('a disallowed origin gets no allow-origin', () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async => HubResponse.text('body'),
      );

      final res = await handler(
        req('GET', headers: {'origin': 'https://evil.example.com'}),
      );

      expect(res.statusCode, 200);
      expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('exposed headers are declared', () async {
      final handler = cors(
        allowedOrigins: [_app],
        exposedHeaders: ['x-request-id'],
      )((_) async => HubResponse.text('body'));

      final res = await handler(req('GET', headers: {'origin': _app}));
      expect(res.headers['access-control-expose-headers'], 'x-request-id');
    });

    test("an existing vary is appended to, not replaced", () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async =>
            HubResponse.text('body', headers: {'vary': 'accept-encoding'}),
      );

      final res = await handler(req('GET', headers: {'origin': _app}));
      expect(res.headers['vary'], 'accept-encoding, Origin');
    });

    test('a streamed body survives the header stamping', () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async => HubResponse.stream(
          Stream.fromIterable([
            [1],
            [2, 3],
          ]),
        ),
      );

      final res = await handler(req('GET', headers: {'origin': _app}));
      expect(await res.readBytes(), [1, 2, 3]);
    });

    test('an SSE response is not silently re-buffered', () async {
      final handler = cors(allowedOrigins: [_app])(
        (_) async => sseResponse(const Stream<SseEvent>.empty()),
      );

      final res = await handler(req('GET', headers: {'origin': _app}));

      expect(res.headers['access-control-allow-origin'], _app);
      expect(
        res.bufferOutput,
        isFalse,
        reason: 'wrapping an event stream in CORS must not strand its events',
      );
    });
  });

  group('cors origin policies', () {
    test('allowAnyOrigin emits the wildcard', () async {
      final handler = cors(allowAnyOrigin: true)(
        (_) async => HubResponse.text('body'),
      );

      final res = await handler(
        req('GET', headers: {'origin': 'https://anywhere.test'}),
      );
      expect(res.headers['access-control-allow-origin'], '*');
      // Nothing to vary on: every origin gets the same answer.
      expect(res.headers.containsKey('vary'), isFalse);
    });

    test(
      'with credentials it reflects the origin — `*` would be illegal',
      () async {
        final handler = cors(allowAnyOrigin: true, allowCredentials: true)(
          (_) async => HubResponse.text('body'),
        );

        final res = await handler(
          req('GET', headers: {'origin': 'https://anywhere.test'}),
        );

        expect(
          res.headers['access-control-allow-origin'],
          'https://anywhere.test',
        );
        expect(res.headers['access-control-allow-credentials'], 'true');
        expect(res.headers['vary'], 'Origin');
      },
    );

    test('the allow-list ignores case and a trailing slash', () async {
      final handler = cors(allowedOrigins: ['https://App.Example.com/'])(
        (_) async => HubResponse.text('body'),
      );

      final res = await handler(req('GET', headers: {'origin': _app}));
      expect(res.headers['access-control-allow-origin'], _app);
    });

    test('a predicate decides, e.g. for wildcard subdomains', () async {
      final handler = cors(allowOrigin: (o) => o.endsWith('.example.com'))(
        (_) async => HubResponse.text('body'),
      );

      final ok = await handler(
        req('GET', headers: {'origin': 'https://team.example.com'}),
      );
      final no = await handler(
        req('GET', headers: {'origin': 'https://example.org'}),
      );

      expect(
        ok.headers['access-control-allow-origin'],
        'https://team.example.com',
      );
      expect(no.headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('no origin policy at all is a programming error', () {
      expect(cors, throwsArgumentError);
    });
  });
}
