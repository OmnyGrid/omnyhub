import 'package:meta/meta.dart';

/// One HTTP header field as it appeared on the wire, name case preserved.
typedef HeaderField = ({String name, String value});

/// The facts a proxy knows about one hop, and how they are added to a
/// request's headers so the upstream can see the original client.
///
/// [apply] uses an **append** policy, the proxy-chain convention: values a
/// client (or an earlier proxy) already sent are kept, and this hop's value is
/// appended after them, comma-separated. The upstream must therefore trust only
/// the right-most entry — the one this hop added — of each list-valued header.
///
/// List-valued headers (appended): `X-Forwarded-For`, `X-Forwarded-Proto`,
/// `X-Forwarded-Host`, `X-Forwarded-Port`, `Forwarded` (RFC 7239), `Via` and
/// every [extra] header.
///
/// Single-valued headers (set only when absent, since a comma list would break
/// their readers): `X-Real-IP`, `X-Forwarded-Ssl` and `X-Request-Id`.
///
/// This class is transport-agnostic: it works on a plain list of header fields,
/// so both a parsed-request proxy and a raw byte-stream rewriter
/// (`HttpRequestHeaderRewriter`) can share it.
@immutable
class ForwardedHeaders {
  /// The original client's IP address, or `null` when unknown.
  final String? clientAddress;

  /// Whether the client reached this hop over TLS (HTTPS).
  final bool secure;

  /// The host the client addressed, used when the request has no `Host`
  /// header. `null` omits `X-Forwarded-Host` in that case.
  final String? host;

  /// The port the client connected to, or `null` to omit `X-Forwarded-Port`.
  final int? port;

  /// The pseudonym this hop adds to `Via` (RFC 9110 §7.6.3).
  final String via;

  /// Extra headers this hop adds (appended like the list-valued headers), e.g.
  /// application context such as a tunnel id.
  final Map<String, String> extra;

  /// Mints an `X-Request-Id` when the request has none, or `null` to never add
  /// one.
  final String Function()? requestId;

  /// Creates the forwarding facts for one hop.
  const ForwardedHeaders({
    this.clientAddress,
    this.secure = false,
    this.host,
    this.port,
    this.via = 'omnyhub',
    this.extra = const {},
    this.requestId,
  });

  /// The scheme the client used: `https` when [secure], otherwise `http`.
  String get proto => secure ? 'https' : 'http';

  /// Returns [headers] with this hop's forwarding headers applied.
  ///
  /// Every header this hop touches is collapsed into one field (repeated
  /// fields are joined with `, `, which RFC 9110 §5.3 makes equivalent) and
  /// moved to the end under its canonical name; all other fields keep their
  /// order and case. [httpVersion] is the request's version (`1.1`), used for
  /// the `Via` entry.
  List<HeaderField> apply(
    List<HeaderField> headers, {
    String httpVersion = '1.1',
  }) {
    final appended = <String, String?>{
      'X-Forwarded-For': clientAddress,
      'X-Forwarded-Proto': proto,
      'X-Forwarded-Host': null,
      'X-Forwarded-Port': port?.toString(),
      'Forwarded': null,
      'Via': '$httpVersion $via',
      for (final e in extra.entries) e.key: e.value,
    };
    final single = <String, String? Function()>{
      'X-Real-IP': () => clientAddress,
      'X-Forwarded-Ssl': () => secure ? 'on' : 'off',
      'X-Request-Id': () => requestId?.call(),
    };
    final managed = {
      for (final name in [...appended.keys, ...single.keys])
        name.toLowerCase(): name,
    };

    final kept = <HeaderField>[];
    final existing = <String, String>{};
    String? requestHost;
    for (final field in headers) {
      final key = field.name.toLowerCase();
      if (key == 'host' && requestHost == null) requestHost = field.value;
      final canonical = managed[key];
      if (canonical == null) {
        kept.add(field);
        continue;
      }
      final prev = existing[canonical];
      existing[canonical] = prev == null
          ? field.value
          : '$prev, ${field.value}';
    }

    final forwardedHost = requestHost ?? host;
    appended['X-Forwarded-Host'] = forwardedHost;
    appended['Forwarded'] = _forwardedElement(forwardedHost);

    final out = [...kept];
    for (final entry in appended.entries) {
      final ours = entry.value == null ? null : _clean(entry.value!);
      final prev = existing[entry.key];
      final value = switch ((prev, ours)) {
        (null, null) => null,
        (final p?, null) => p,
        (null, final o?) => o,
        (final p?, final o?) => '$p, $o',
      };
      if (value != null) out.add((name: entry.key, value: value));
    }
    for (final entry in single.entries) {
      final prev = existing[entry.key];
      final value = prev ?? entry.value();
      if (value != null) out.add((name: entry.key, value: _clean(value)));
    }
    return out;
  }

  /// This hop's RFC 7239 `Forwarded` element: `for=…;proto=…;host=…`.
  String _forwardedElement(String? forwardedHost) {
    final parts = <String>[];
    final client = clientAddress;
    if (client != null) {
      parts.add(
        client.contains(':') ? 'for="[$client]"' : 'for=${_token(client)}',
      );
    }
    parts.add('proto=$proto');
    if (forwardedHost != null) parts.add('host=${_quote(forwardedHost)}');
    return parts.join(';');
  }

  static final _tokenChars = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

  static String _token(String s) => _tokenChars.hasMatch(s) ? s : _quote(s);

  static String _quote(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// Drops control characters (CR/LF above all) so a value can never split
  /// or inject a header line.
  static String _clean(String s) =>
      s.replaceAll(RegExp(r'[\x00-\x08\x0A-\x1F\x7F]'), '');
}
