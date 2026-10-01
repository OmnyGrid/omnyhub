@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// A raw TCP relay in front of a real HTTP server, rewriting the client→server
/// stream with [HttpRequestHeaderRewriter] + [ForwardedHeaders] — the shape a
/// byte-level tunnel uses.
void main() {
  late HttpServer backend;
  late ServerSocket front;
  final seen = <Map<String, Object?>>[];
  var connections = 0;

  setUp(() async {
    seen.clear();
    connections = 0;
    backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    backend.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((m) => ws.add('echo:$m'), onDone: ws.close);
        return;
      }
      final body = await utf8.decodeStream(req);
      seen.add({
        'path': req.uri.path,
        'body': body,
        'xff': req.headers.value('x-forwarded-for'),
        'proto': req.headers.value('x-forwarded-proto'),
        'host': req.headers.value('x-forwarded-host'),
        'port': req.headers.value('x-forwarded-port'),
        'forwarded': req.headers.value('forwarded'),
        'via': req.headers.value('via'),
        'requestId': req.headers.value('x-request-id'),
      });
      req.response
        ..write('ok:${req.uri.path}:${body.length}')
        ..close();
    });

    var ids = 0;
    front = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    front.listen((client) async {
      connections++;
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        backend.port,
      );
      final rewriter = HttpRequestHeaderRewriter(
        (head) => ForwardedHeaders(
          clientAddress: client.remoteAddress.address,
          port: front.port,
          via: 'test-hub',
          requestId: () => 'req-${++ids}',
        ).apply(head.headers, httpVersion: head.version),
      );
      client.listen(
        (data) => upstream.add(rewriter.add(data)),
        onDone: upstream.close,
        onError: (_) => upstream.destroy(),
      );
      upstream.listen(
        client.add,
        onDone: client.close,
        onError: (_) => client.destroy(),
      );
    });
  });

  tearDown(() async {
    await front.close();
    await backend.close(force: true);
  });

  test('every keep-alive request gets the forwarding headers', () async {
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${front.port}');

    Future<String> send(String method, String path, {String? body}) async {
      final req = await http.openUrl(method, base.resolve(path));
      if (body != null) {
        // Streamed without a length, so the client sends it chunked.
        req.headers.chunkedTransferEncoding = true;
        req.write(body);
      }
      final res = await req.close();
      return utf8.decodeStream(res);
    }

    expect(await send('GET', '/one'), 'ok:/one:0');
    expect(await send('POST', '/two', body: 'x' * 70000), 'ok:/two:70000');
    expect(await send('GET', '/three'), 'ok:/three:0');

    expect(connections, 1, reason: 'requests must share one connection');
    expect(seen.map((s) => s['path']), ['/one', '/two', '/three']);
    for (final (i, s) in seen.indexed) {
      expect(s['xff'], '127.0.0.1');
      expect(s['proto'], 'http');
      expect(s['host'], '127.0.0.1:${front.port}');
      expect(s['port'], '${front.port}');
      expect(
        s['forwarded'],
        'for=127.0.0.1;proto=http;host="127.0.0.1:${front.port}"',
      );
      expect(s['via'], '1.1 test-hub');
      expect(s['requestId'], 'req-${i + 1}');
    }
  });

  test('a fixed-length body is forwarded byte for byte', () async {
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final body = 'GET /smuggled HTTP/1.1\r\n\r\n' * 100;
    final req = await http.post('127.0.0.1', front.port, '/len');
    req.contentLength = body.length;
    req.write(body);
    final res = await req.close();
    expect(await utf8.decodeStream(res), 'ok:/len:${body.length}');
    expect(seen.single['body'], body);
  });

  test('a WebSocket passes through after its upgrade', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${front.port}/ws');
    addTearDown(ws.close);
    ws.add('hi');
    expect(await ws.first, 'echo:hi');
  });
}
