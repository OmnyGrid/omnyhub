import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

Uint8List b(String s) => latin1.encode(s);

/// A compact, comparable rendering of [events].
List<String> describe(List<HttpStreamEvent> events) => [
  for (final e in events)
    switch (e) {
      HttpRequestHeadEvent(:final head) => 'req ${head.method} ${head.target}',
      HttpResponseHeadEvent(:final head) => 'resp ${head.status}',
      HttpBodyEvent() => 'body ${jsonEncode(latin1.decode(e.raw))}',
      HttpMessageEndEvent() => 'end',
      HttpGapEvent() => 'gap',
      HttpPassthroughEvent() => 'pass ${jsonEncode(latin1.decode(e.raw))}',
    },
];

/// Feeds [input] whole and in 1-byte pieces, expecting the same raw bytes.
List<HttpStreamEvent> feed(HttpStreamParser Function() make, String input) {
  final whole = make().add(b(input));
  final p = make();
  final pieces = [
    for (final c in b(input)) ...p.add(Uint8List.fromList([c])),
  ];
  String raw(List<HttpStreamEvent> es) =>
      latin1.decode([for (final e in es) ...e.raw]);
  expect(raw(pieces), raw(whole), reason: 'byte-split must not change bytes');
  return whole;
}

void main() {
  group('responses', () {
    HttpStreamParser make([List<String> methods = const ['GET']]) {
      final p = HttpStreamParser.responses();
      methods.forEach(p.expectResponseTo);
      return p;
    }

    test('Content-Length body', () {
      final p = make();
      expect(
        describe(p.add(b('HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc'))),
        ['resp 200', 'body "abc"', 'end'],
      );
      expect(p.isIdle, isTrue);
    });

    test('chunked body with trailers, then the next response', () {
      final p = make(['GET', 'GET']);
      final es = feed(
        () => make(['GET', 'GET']),
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '3\r\nabc\r\n0\r\nX-T: 1\r\n\r\n'
        'HTTP/1.1 204 No Content\r\n\r\n',
      );
      expect(describe(es).where((d) => !d.startsWith('body')), [
        'resp 200',
        'end',
        'resp 204',
        'end',
      ]);
      expect(p.isPassthrough, isFalse);
    });

    test('no length means a close-delimited body', () {
      final p = make();
      expect(describe(p.add(b('HTTP/1.1 200 OK\r\n\r\nabc'))), [
        'resp 200',
        'body "abc"',
      ]);
      expect(describe(p.add(b('def'))), ['body "def"']);
      expect(describe(p.close()), ['end']);
    });

    test('a non-chunked Transfer-Encoding is close-delimited too', () {
      final p = make();
      p.add(b('HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nzz'));
      expect(describe(p.close()), ['end']);
    });

    test('HEAD, 204 and 304 responses have no body', () {
      final p = make(['HEAD', 'GET', 'GET']);
      expect(
        describe(
          p.add(
            b(
              'HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n'
              'HTTP/1.1 204 No Content\r\n\r\n'
              'HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n',
            ),
          ),
        ),
        ['resp 200', 'end', 'resp 204', 'end', 'resp 304', 'end'],
      );
    });

    test('interim 1xx responses keep the expectation', () {
      final p = make(['HEAD']);
      expect(
        describe(
          p.add(
            b(
              'HTTP/1.1 100 Continue\r\n\r\n'
              'HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n'
              'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n',
            ),
          ),
        ),
        ['resp 100', 'end', 'resp 103', 'end', 'resp 200', 'end'],
      );
    });

    test('101 switches to pass-through', () {
      final p = make();
      final es = p.add(b('HTTP/1.1 101 Switching Protocols\r\n\r\n\x81\x02hi'));
      expect(describe(es).take(2), ['resp 101', 'end']);
      expect(es.last, isA<HttpPassthroughEvent>());
      expect(es.last.raw, [0x81, 0x02, 0x68, 0x69]);
      expect(p.isPassthrough, isTrue);
      expect(describe(p.add(b('x'))), ['pass "x"']);
    });

    test('a successful CONNECT switches to pass-through', () {
      final p = make(['CONNECT']);
      p.add(b('HTTP/1.1 200 Connection Established\r\n\r\n'));
      expect(p.isPassthrough, isTrue);
    });

    test('no expectation defaults to GET framing', () {
      final p = HttpStreamParser.responses();
      expect(
        describe(p.add(b('HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx'))),
        ['resp 200', 'body "x"', 'end'],
      );
    });

    test('the status line may omit the reason', () {
      final p = make();
      final es = p.add(b('HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n'));
      final head = (es.first as HttpResponseHeadEvent).head;
      expect(head.reason, '');
      expect(head.version, '1.1');
      expect(
        latin1.decode(encodeHttpResponseHead(head)),
        startsWith('HTTP/1.1 200\r\n'),
      );
    });

    for (final bad in [
      'HTTP/2 200 OK\r\n\r\n',
      'HTTP/1.1 2000 OK\r\n\r\n',
      'SSH-2.0-OpenSSH\r\n\r\n',
      'HTTP/1.1 200 OK\r\nbad line\r\n\r\n',
    ]) {
      test('unparseable ${jsonEncode(bad)} passes through', () {
        final p = make();
        expect(describe(p.add(b(bad))), ['pass ${jsonEncode(bad)}']);
        expect(p.isPassthrough, isTrue);
      });
    }

    test('an invalid Content-Length passes through', () {
      final p = make();
      p.add(b('HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n'));
      expect(p.isPassthrough, isTrue);
    });

    test('close reports a partial head as pass-through', () {
      final p = make();
      expect(p.add(b('HTTP/1.1 200 OK\r\nX-A')), isEmpty);
      expect(p.isIdle, isFalse);
      expect(describe(p.close()), ['pass "HTTP/1.1 200 OK\\r\\nX-A"']);
    });

    test('an oversized head passes through', () {
      final p = HttpStreamParser.responses(maxHeadBytes: 16)
        ..expectResponseTo('GET');
      final es = p.add(b('HTTP/1.1 200 OK\r\nX-Long: ${'a' * 40}'));
      expect(es.single, isA<HttpPassthroughEvent>());
    });
  });

  group('requests', () {
    test('head, body and end events carry raw bytes', () {
      final p = HttpStreamParser.requests();
      final es = p.add(
        b(
          'POST /p HTTP/1.1\r\nContent-Length: 2\r\n\r\nokGET / HTTP/1.1\r\n\r\n',
        ),
      );
      expect(describe(es), [
        'req POST /p',
        'body "ok"',
        'end',
        'req GET /',
        'end',
      ]);
      expect(
        latin1.decode(es.first.raw),
        'POST /p HTTP/1.1\r\nContent-Length: 2\r\n\r\n',
      );
    });

    test('stray CRLFs are gaps', () {
      final p = HttpStreamParser.requests();
      expect(describe(p.add(b('\r\nGET / HTTP/1.1\r\n\r\n'))), [
        'gap',
        'req GET /',
        'end',
      ]);
    });

    test('an upgrade request ends framing after its head', () {
      final p = HttpStreamParser.requests();
      expect(
        describe(
          p.add(
            b(
              'GET /ws HTTP/1.1\r\nUpgrade: websocket\r\n'
              'Connection: Upgrade\r\n\r\nraw',
            ),
          ),
        ),
        ['req GET /ws', 'end', 'pass "raw"'],
      );
    });

    test('a request with no length has no body', () {
      final p = HttpStreamParser.requests();
      expect(describe(p.add(b('DELETE /x HTTP/1.1\r\n\r\n'))), [
        'req DELETE /x',
        'end',
      ]);
    });

    test('close on an idle request parser emits nothing', () {
      final p = HttpStreamParser.requests();
      p.add(b('GET / HTTP/1.1\r\n\r\n'));
      expect(p.close(), isEmpty);
    });
  });

  group('helpers', () {
    const headers = [
      (name: 'Cache-Control', value: 'public'),
      (name: 'cache-control', value: ' max-age=60 '),
      (name: 'X', value: ''),
    ];

    test('headerValue joins repeated fields case-insensitively', () {
      expect(headerValue(headers, 'CACHE-CONTROL'), 'public, max-age=60 ');
      expect(headerValue(headers, 'missing'), isNull);
    });

    test('headerTokens splits, trims and lower-cases', () {
      expect(headerTokens(headers, 'cache-control'), ['public', 'max-age=60']);
      expect(headerTokens(headers, 'x'), isEmpty);
      expect(headerTokens(headers, 'missing'), isEmpty);
    });

    test('encodeHttpRequestHead writes a request head', () {
      expect(
        latin1.decode(
          encodeHttpRequestHead((
            method: 'GET',
            target: '/',
            version: '1.1',
            headers: const [(name: 'Host', value: 'h')],
          )),
        ),
        'GET / HTTP/1.1\r\nHost: h\r\n\r\n',
      );
    });

    test('parse helpers reject non-HTTP text', () {
      expect(HttpStreamParser.parseRequestHead(''), isNull);
      expect(HttpStreamParser.parseResponseHead('nope'), isNull);
    });
  });
}
