import 'dart:async';
import 'dart:convert';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  group('SseEvent.encode', () {
    test('a bare event is one data line and the dispatching blank line', () {
      expect(const SseEvent('hi').encode(), 'data: hi\n\n');
    });

    test('multi-line data becomes one data line per line', () {
      expect(
        const SseEvent('a\nb\r\nc\rd').encode(),
        'data: a\ndata: b\ndata: c\ndata: d\n\n',
      );
    });

    test('empty data still writes a data line', () {
      expect(const SseEvent('').encode(), 'data: \n\n');
    });

    test('id, event and retry precede the data, and retry is milliseconds', () {
      final encoded = SseEvent(
        'payload',
        id: '7',
        event: 'tick',
        retry: const Duration(seconds: 3),
      ).encode();
      expect(encoded, 'id: 7\nevent: tick\nretry: 3000\ndata: payload\n\n');
    });

    test(
      'newlines are stripped from id and event — they cannot span lines',
      () {
        final encoded = const SseEvent(
          'x',
          id: 'a\nb',
          event: 'c\r\nd',
        ).encode();
        expect(encoded, 'id: a b\nevent: c d\ndata: x\n\n');
      },
    );

    test('SseEvent.json encodes the value as its data', () {
      expect(
        SseEvent.json({'a': 1}, event: 'update').encode(),
        'event: update\ndata: {"a":1}\n\n',
      );
    });
  });

  group('encodeSseEvents', () {
    test(
      'forwards each event, encoded, and closes when the source does',
      () async {
        final source = StreamController<SseEvent>();
        final chunks = <String>[];
        final done = Completer<void>();
        encodeSseEvents(source.stream, keepAlive: Duration.zero).listen(
          (bytes) => chunks.add(utf8.decode(bytes)),
          onDone: done.complete,
        );

        source
          ..add(const SseEvent('one'))
          ..add(const SseEvent('two', event: 'named'));
        await Future<void>.delayed(Duration.zero);
        await source.close();
        await done.future;

        expect(chunks, ['data: one\n\n', 'event: named\ndata: two\n\n']);
      },
    );

    test('emits a keep-alive comment while idle', () async {
      final source = StreamController<SseEvent>();
      final chunks = <String>[];
      final sub = encodeSseEvents(
        source.stream,
        keepAlive: const Duration(milliseconds: 20),
      ).listen((bytes) => chunks.add(utf8.decode(bytes)));

      await _until(() => chunks.any((c) => c == ': ping\n\n'));
      await sub.cancel();
      await source.close();
    });

    test('cancelling releases the source and stops the pings', () async {
      var sourceCancelled = false;
      var onCancelCalled = false;
      final source = StreamController<SseEvent>(
        onCancel: () => sourceCancelled = true,
      );
      final chunks = <List<int>>[];
      final sub = encodeSseEvents(
        source.stream,
        keepAlive: const Duration(milliseconds: 10),
        onCancel: () => onCancelCalled = true,
      ).listen(chunks.add);

      await _until(() => chunks.isNotEmpty);
      await sub.cancel();
      final afterCancel = chunks.length;

      expect(sourceCancelled, isTrue, reason: 'the source must be released');
      expect(onCancelCalled, isTrue, reason: 'the disconnect hook must fire');

      // The ping timer is dead: nothing more arrives.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(chunks.length, afterCancel);
      await source.close();
    });
  });

  group('sseResponse', () {
    test('is an unbuffered text/event-stream', () {
      final res = sseResponse(const Stream<SseEvent>.empty());
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'text/event-stream; charset=utf-8');
      expect(res.headers['cache-control'], 'no-cache, no-transform');
      expect(res.headers['x-accel-buffering'], 'no');
      // The whole point: dart:io must not hold events in its 8 KiB buffer.
      expect(res.bufferOutput, isFalse);
    });

    test('streams the encoded events as the body', () async {
      final res = sseResponse(
        Stream.fromIterable([const SseEvent('a'), const SseEvent('b')]),
        keepAlive: Duration.zero,
      );
      expect(await res.readAsString(), 'data: a\n\ndata: b\n\n');
    });

    test('caller headers override the defaults', () {
      final res = sseResponse(
        const Stream<SseEvent>.empty(),
        headers: {'cache-control': 'private'},
      );
      expect(res.headers['cache-control'], 'private');
    });
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
