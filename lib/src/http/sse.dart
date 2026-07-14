import 'dart:async';
import 'dart:convert';

import 'hub_response.dart';

/// One Server-Sent Event.
///
/// The wire format is line-oriented and dispatched by a blank line, so [data]
/// spanning several lines is emitted as several `data:` lines, and [id]/[event],
/// which cannot span lines at all, have any newlines stripped.
class SseEvent {
  /// The payload delivered to the browser's `EventSource` as `event.data`.
  final String data;

  /// The event name. `null` means the default `message` type, which a listener
  /// receives via `onmessage`; a name is delivered to
  /// `addEventListener(name, …)` instead.
  final String? event;

  /// The event id. The browser remembers the last one it saw and replays it as
  /// the `last-event-id` header when it reconnects, so a stream can resume.
  final String? id;

  /// How long the browser should wait before reconnecting if the stream drops.
  final Duration? retry;

  /// Creates an event carrying [data].
  const SseEvent(this.data, {this.event, this.id, this.retry});

  /// An event whose [data] is [value] encoded as JSON.
  factory SseEvent.json(
    Object? value, {
    String? event,
    String? id,
    Duration? retry,
  }) => SseEvent(jsonEncode(value), event: event, id: id, retry: retry);

  /// This event in SSE wire form, terminated by the blank line that dispatches
  /// it.
  String encode() {
    final out = StringBuffer();
    if (id != null) out.write('id: ${_oneLine(id!)}\n');
    if (event != null) out.write('event: ${_oneLine(event!)}\n');
    if (retry != null) out.write('retry: ${retry!.inMilliseconds}\n');
    for (final line in data.split(_newline)) {
      out.write('data: $line\n');
    }
    out.write('\n');
    return out.toString();
  }

  /// This event in SSE wire form, as UTF-8 bytes.
  List<int> encodeBytes() => utf8.encode(encode());

  static final RegExp _newline = RegExp(r'\r\n|\r|\n');

  static String _oneLine(String value) => value.replaceAll(_newline, ' ');

  @override
  String toString() => 'SseEvent(${event ?? 'message'}, ${data.length} chars)';
}

/// Encodes [events] as an SSE byte stream, emitting a comment line every
/// [keepAlive] while the stream is idle ([Duration.zero] disables it).
///
/// The keep-alive is not only an idle-timeout defence: without traffic, a
/// connection whose client has vanished is never noticed, so the ping is what
/// eventually fails to write and surfaces the disconnect. [onCancel] fires when
/// the client goes away (the transport cancels its subscription) — release
/// per-client resources there and stop producing.
Stream<List<int>> encodeSseEvents(
  Stream<SseEvent> events, {
  Duration keepAlive = const Duration(seconds: 15),
  String keepAliveComment = 'ping',
  void Function()? onCancel,
}) {
  StreamSubscription<SseEvent>? subscription;
  Timer? pinger;
  late StreamController<List<int>> controller;

  controller = StreamController<List<int>>(
    onListen: () {
      subscription = events.listen(
        (event) {
          if (!controller.isClosed) controller.add(event.encodeBytes());
        },
        onError: controller.addError,
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
      );
      if (keepAlive > Duration.zero) {
        pinger = Timer.periodic(keepAlive, (_) {
          if (!controller.isClosed) {
            controller.add(utf8.encode(': $keepAliveComment\n\n'));
          }
        });
      }
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      pinger?.cancel();
      await subscription?.cancel();
      onCancel?.call();
    },
  );

  return controller.stream;
}

/// A `text/event-stream` [HubResponse] pushing [events] to the client.
///
/// ```dart
/// HandlerService(
///   name: 'events',
///   mount: '/events',
///   handler: (request) async => sseResponse(bus.stream.map(SseEvent.json)),
/// );
/// ```
///
/// Events are flushed as they are produced — see [HubResponse.bufferOutput] for
/// why that needs saying.
HubResponse sseResponse(
  Stream<SseEvent> events, {
  int statusCode = 200,
  Duration keepAlive = const Duration(seconds: 15),
  Map<String, String> headers = const {},
  void Function()? onCancel,
}) => HubResponse.eventStream(
  encodeSseEvents(events, keepAlive: keepAlive, onCancel: onCancel),
  statusCode: statusCode,
  headers: headers,
);
