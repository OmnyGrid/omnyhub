@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

/// Server-Sent Events over a real socket.
///
/// These are the tests that pin the reason [HubResponse.bufferOutput] exists.
/// `dart:io` buffers output and flushes only when an 8 KiB buffer fills or the
/// response closes; a live stream closes never and its events are tiny, so
/// without the flag nothing — not even the response headers — reaches the
/// client. `http.get` would buffer the whole body and hang forever here, so
/// these drive the socket with `Client.send` and read the stream incrementally.
void main() {
  late HttpTransport transport;
  late http.Client client;
  late StreamController<SseEvent> events;
  var cancelled = false;

  setUp(() {
    cancelled = false;
    events = StreamController<SseEvent>();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    if (!events.isClosed) await events.close();
    await transport.close(force: true);
  });

  Future<http.StreamedResponse> serve({
    Duration keepAlive = const Duration(milliseconds: 50),
  }) async {
    transport = HttpTransport.http(address: '127.0.0.1', port: 0);
    await transport.bind(
      onRequest: (_) async => sseResponse(
        events.stream,
        keepAlive: keepAlive,
        onCancel: () => cancelled = true,
      ),
    );
    return client.send(
      http.Request('GET', Uri.parse('http://127.0.0.1:${transport.port}/e')),
    );
  }

  test('a small event reaches the client immediately', () async {
    final res = await serve();
    expect(res.statusCode, 200);
    expect(res.headers['content-type'], contains('text/event-stream'));

    final chunks = <String>[];
    final sub = res.stream.transform(utf8.decoder).listen(chunks.add);

    events.add(const SseEvent('hello', event: 'greeting'));

    // ~30 bytes. If output buffering were left on, this would sit in dart:io's
    // 8 KiB buffer and never arrive — the response is still open, so nothing
    // will ever flush it.
    await _until(() => chunks.join().contains('data: hello'));
    expect(chunks.join(), contains('event: greeting'));
    expect(
      chunks.join().length,
      lessThan(8192),
      reason: 'it arrived without 8 KiB of padding forcing a flush',
    );

    await sub.cancel();
  });

  test('events keep arriving while the response stays open', () async {
    final res = await serve();
    final chunks = <String>[];
    final sub = res.stream.transform(utf8.decoder).listen(chunks.add);

    events.add(const SseEvent('first'));
    await _until(() => chunks.join().contains('first'));

    events.add(const SseEvent('second'));
    await _until(() => chunks.join().contains('second'));

    expect(
      events.isClosed,
      isFalse,
      reason: 'the stream is live, not flushed at close',
    );
    await sub.cancel();
  });

  test('an idle stream is kept alive by comment pings', () async {
    final res = await serve();
    final chunks = <String>[];
    final sub = res.stream.transform(utf8.decoder).listen(chunks.add);

    // No events at all — only the keep-alive should appear.
    await _until(() => chunks.join().contains(': ping'));
    await sub.cancel();
  });

  test('a client that goes away is noticed, and the source released', () async {
    final res = await serve();
    final sub = res.stream.transform(utf8.decoder).listen((_) {});

    events.add(const SseEvent('hi'));
    await _until(() => true);

    await sub.cancel();
    client.close();

    // The next ping fails to write, dart:io errors the body stream, the
    // subscription is cancelled and onCancel fires. This is the only way a
    // vanished client is ever detected.
    await _until(() => cancelled);
    expect(cancelled, isTrue);
  });

  test('an SSE stream hosted on a hub, through CORS, still streams', () async {
    transport = HttpTransport.http(address: '127.0.0.1', port: 0);
    final hub = OmnyHub(
      transports: [transport],
      outerMiddleware: [
        cors(allowedOrigins: ['https://app.test']),
      ],
    );
    await hub.registerService(
      HandlerService(
        name: 'events',
        mount: '/events',
        handler: (_) async => sseResponse(
          events.stream,
          keepAlive: const Duration(milliseconds: 50),
        ),
      ),
    );
    await hub.start();
    addTearDown(hub.stop);

    final request = http.Request(
      'GET',
      Uri.parse('http://127.0.0.1:${transport.port}/events'),
    )..headers['origin'] = 'https://app.test';
    final res = await client.send(request);

    expect(res.headers['access-control-allow-origin'], 'https://app.test');

    final chunks = <String>[];
    final sub = res.stream.transform(utf8.decoder).listen(chunks.add);
    events.add(const SseEvent('through-cors'));

    // Guards the withHeaders() bufferOutput hand-off: wrapping the response in
    // CORS must not silently re-buffer it.
    await _until(() => chunks.join().contains('through-cors'));
    await sub.cancel();
  });
}

/// Polls [condition] until true or a short timeout elapses.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!condition()) throw StateError('condition not met before timeout');
}
