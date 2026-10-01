import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// A rewriter that appends `X-Seen: <n>` to the n-th request, recording heads.
({HttpRequestHeaderRewriter rewriter, List<HttpRequestHead> heads}) tagger({
  int maxHeadBytes = 64 * 1024,
}) {
  final heads = <HttpRequestHead>[];
  final rewriter = HttpRequestHeaderRewriter((head) {
    heads.add(head);
    return [...head.headers, (name: 'X-Seen', value: '${heads.length}')];
  }, maxHeadBytes: maxHeadBytes);
  return (rewriter: rewriter, heads: heads);
}

/// Feeds [input] in pieces of [step] bytes (all at once when null).
String feed(HttpRequestHeaderRewriter r, String input, {int? step}) {
  final bytes = latin1.encode(input);
  final out = BytesBuilder();
  final n = step ?? bytes.length;
  for (var i = 0; i < bytes.length; i += n) {
    final end = i + n > bytes.length ? bytes.length : i + n;
    out.add(r.add(Uint8List.sublistView(bytes, i, end)));
  }
  return latin1.decode(out.takeBytes());
}

void main() {
  for (final step in [null, 1, 3, 7]) {
    group('fed ${step == null ? 'at once' : 'in $step-byte pieces'}', () {
      test('rewrites a bodiless request', () {
        final t = tagger();
        expect(
          feed(t.rewriter, 'GET /a HTTP/1.1\r\nHost: h\r\n\r\n', step: step),
          'GET /a HTTP/1.1\r\nHost: h\r\nX-Seen: 1\r\n\r\n',
        );
        expect(t.heads.single.method, 'GET');
        expect(t.heads.single.target, '/a');
        expect(t.heads.single.version, '1.1');
      });

      test('rewrites every keep-alive request but never a body', () {
        final t = tagger();
        // The body looks like a request; it must pass through untouched.
        const body = 'GET /fake HTTP/1.1\r\n\r\n';
        final input =
            'POST /p HTTP/1.1\r\nContent-Length: ${body.length}\r\n\r\n$body'
            'GET /b HTTP/1.1\r\n\r\n';
        expect(
          feed(t.rewriter, input, step: step),
          'POST /p HTTP/1.1\r\nContent-Length: ${body.length}\r\nX-Seen: 1'
          '\r\n\r\n${body}GET /b HTTP/1.1\r\nX-Seen: 2\r\n\r\n',
        );
        expect(t.heads.map((h) => h.target), ['/p', '/b']);
      });

      test('follows chunked bodies, extensions and trailers', () {
        final t = tagger();
        const chunked =
            '5;ext=1\r\nGET /\r\n'
            '3\r\nabc\r\n'
            '0\r\nX-Trailer: t\r\n\r\n';
        final input =
            'POST /c HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n'
            '${chunked}GET /after HTTP/1.1\r\n\r\n';
        expect(
          feed(t.rewriter, input, step: step),
          'POST /c HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n'
          'X-Seen: 1\r\n\r\n${chunked}GET /after HTTP/1.1\r\nX-Seen: 2\r\n\r\n',
        );
        expect(t.rewriter.isPassthrough, isFalse);
      });

      test('passes through everything after a WebSocket upgrade', () {
        final t = tagger();
        final input =
            'GET /ws HTTP/1.1\r\nConnection: keep-alive, Upgrade\r\n'
            'Upgrade: websocket\r\n\r\n'
            'GET /not-http HTTP/1.1\r\n\r\n';
        expect(
          feed(t.rewriter, input, step: step),
          'GET /ws HTTP/1.1\r\nConnection: keep-alive, Upgrade\r\n'
          'Upgrade: websocket\r\nX-Seen: 1\r\n\r\n'
          'GET /not-http HTTP/1.1\r\n\r\n',
        );
        expect(t.rewriter.isPassthrough, isTrue);
      });
    });
  }

  test('an Upgrade header without Connection: upgrade keeps framing', () {
    final t = tagger();
    feed(t.rewriter, 'GET / HTTP/1.1\r\nUpgrade: h2c\r\n\r\n');
    expect(t.rewriter.isPassthrough, isFalse);
  });

  test('passes through after CONNECT', () {
    final t = tagger();
    final out = feed(
      t.rewriter,
      'CONNECT h:443 HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n',
    );
    expect(
      out,
      'CONNECT h:443 HTTP/1.1\r\nX-Seen: 1\r\n\r\nGET / HTTP/1.1\r\n\r\n',
    );
  });

  test('a non-chunked Transfer-Encoding is read to close (pass-through)', () {
    final t = tagger();
    feed(t.rewriter, 'POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n');
    expect(t.rewriter.isPassthrough, isTrue);
  });

  test('Transfer-Encoding wins over Content-Length', () {
    final t = tagger();
    final out = feed(
      t.rewriter,
      'POST / HTTP/1.1\r\nContent-Length: 100\r\n'
      'Transfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /n HTTP/1.1\r\n\r\n',
    );
    expect(out, endsWith('GET /n HTTP/1.1\r\nX-Seen: 2\r\n\r\n'));
  });

  test('repeated identical Content-Lengths are accepted', () {
    final t = tagger();
    final out = feed(
      t.rewriter,
      'POST / HTTP/1.1\r\nContent-Length: 2, 2\r\nContent-Length: 2\r\n\r\n'
      'okGET /n HTTP/1.1\r\n\r\n',
    );
    expect(out, endsWith('okGET /n HTTP/1.1\r\nX-Seen: 2\r\n\r\n'));
  });

  for (final cl in ['1, 2', 'abc', '-1']) {
    test('an invalid Content-Length ($cl) passes through', () {
      final t = tagger();
      feed(t.rewriter, 'POST / HTTP/1.1\r\nContent-Length: $cl\r\n\r\n');
      expect(t.rewriter.isPassthrough, isTrue);
    });
  }

  test('Content-Length: 0 goes straight to the next request', () {
    final t = tagger();
    feed(
      t.rewriter,
      'POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nGET / HTTP/1.1\r\n\r\n',
    );
    expect(t.heads, hasLength(2));
  });

  for (final input in [
    'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n',
    '\x16\x03\x01\x00\xa5\x01\x00\x00\xa1\x03\x03\n\n',
    'GET /\r\n\r\n',
    'GET / HTTP/1.1\r\nno-colon-here\r\n\r\n',
    'GET / HTTP/1.1\r\n: empty-name\r\n\r\n',
    'GET / HTTP/1.1\r\nBad Name: x\r\n\r\n',
    'GET / HTTP/1.1\r\n folded-first: x\r\n\r\n',
    'G(T / HTTP/1.1\r\n\r\n',
  ]) {
    test(
      'non-HTTP/1.x input passes through unchanged: ${jsonEncode(input)}',
      () {
        final t = tagger();
        expect(feed(t.rewriter, input), input);
        expect(t.rewriter.isPassthrough, isTrue);
        expect(t.heads, isEmpty);
      },
    );
  }

  test('an oversized head gives up and passes through', () {
    final t = tagger(maxHeadBytes: 32);
    final input = 'GET / HTTP/1.1\r\nX-Long: ${'a' * 64}\r\n\r\n';
    expect(feed(t.rewriter, input, step: 8), input);
    expect(t.rewriter.isPassthrough, isTrue);
  });

  test('an oversized chunk-size line gives up and passes through', () {
    final t = tagger(maxHeadBytes: 16);
    const head = 'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n';
    final line = '1${'0' * 40}';
    final out = feed(t.rewriter, '$head$line', step: 4);
    expect(out, endsWith(line));
    expect(t.rewriter.isPassthrough, isTrue);
  });

  test('an invalid chunk size passes through', () {
    final t = tagger();
    final out = feed(
      t.rewriter,
      'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nGET /\r\n',
    );
    expect(out, endsWith('zz\r\nGET /\r\n'));
    expect(t.rewriter.isPassthrough, isTrue);
  });

  test('stray CRLFs between requests are forwarded and skipped', () {
    final t = tagger();
    final out = feed(
      t.rewriter,
      'GET /1 HTTP/1.1\r\n\r\n\r\n\r\nGET /2 HTTP/1.1\r\n\r\n',
      step: 1,
    );
    expect(out, contains('\r\n\r\n\r\n\r\nGET /2'));
    expect(t.heads.map((h) => h.target), ['/1', '/2']);
  });

  test('accepts bare-LF line endings and HTTP/1.0', () {
    final t = tagger();
    final out = feed(t.rewriter, 'GET / HTTP/1.0\nHost: h\n\n');
    expect(out, 'GET / HTTP/1.0\r\nHost: h\r\nX-Seen: 1\r\n\r\n');
    expect(t.heads.single.version, '1.0');
  });

  test('joins obsolete folded header lines', () {
    final t = tagger();
    feed(t.rewriter, 'GET / HTTP/1.1\r\nX-A: one\r\n  two\r\n\r\n');
    expect(t.heads.single.headers.single, (name: 'X-A', value: 'one two'));
  });

  test('characters outside Latin-1 are written as "?"', () {
    final r = HttpRequestHeaderRewriter(
      (h) => [(name: 'X-U', value: 'café ✓')],
    );
    final out = r.add(latin1.encode('GET / HTTP/1.1\r\n\r\n'));
    expect(latin1.decode(out), 'GET / HTTP/1.1\r\nX-U: café ?\r\n\r\n');
  });

  test('works with ForwardedHeaders as the rewrite', () {
    final r = HttpRequestHeaderRewriter(
      (h) => const ForwardedHeaders(
        clientAddress: '1.2.3.4',
        secure: true,
      ).apply(h.headers, httpVersion: h.version),
    );
    final out = latin1.decode(
      r.add(latin1.encode('GET / HTTP/1.0\r\nHost: h\r\n\r\n')),
    );
    expect(out, contains('X-Forwarded-For: 1.2.3.4\r\n'));
    expect(out, contains('X-Forwarded-Proto: https\r\n'));
    expect(out, contains('Via: 1.0 omnyhub\r\n'));
  });
}
