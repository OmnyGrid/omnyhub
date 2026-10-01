import 'dart:io' show HttpDate;

import '../forwarded_headers.dart';
import '../http_stream_parser.dart';

/// The parsed directives of a `Cache-Control` header (RFC 9111 §5.2).
///
/// Directive names are lower-cased; quoted values are unquoted. Repeated
/// header fields are combined, and a directive given twice keeps its first
/// value.
class CacheControl {
  /// The directives, name → value (`null` for a directive without one).
  final Map<String, String?> directives;

  /// Wraps already-parsed [directives].
  const CacheControl(this.directives);

  /// Parses the `Cache-Control` fields of [headers].
  factory CacheControl.of(List<HeaderField> headers) =>
      CacheControl.parse(headerValue(headers, 'cache-control'));

  /// Parses a `Cache-Control` value; `null` or empty yields no directives.
  factory CacheControl.parse(String? value) {
    final out = <String, String?>{};
    if (value == null) return CacheControl(out);
    var i = 0;
    while (i < value.length) {
      // Directive name up to '=' or ','.
      final start = i;
      while (i < value.length && value[i] != '=' && value[i] != ',') {
        i++;
      }
      final name = value.substring(start, i).trim().toLowerCase();
      String? arg;
      if (i < value.length && value[i] == '=') {
        i++;
        while (i < value.length && value[i] == ' ') {
          i++;
        }
        if (i < value.length && value[i] == '"') {
          i++;
          final sb = StringBuffer();
          while (i < value.length && value[i] != '"') {
            if (value[i] == r'\' && i + 1 < value.length) i++;
            sb.write(value[i]);
            i++;
          }
          i++; // closing quote
          arg = sb.toString();
          while (i < value.length && value[i] != ',') {
            i++;
          }
        } else {
          final s = i;
          while (i < value.length && value[i] != ',') {
            i++;
          }
          arg = value.substring(s, i).trim();
        }
      }
      if (i < value.length && value[i] == ',') i++;
      if (name.isNotEmpty) out.putIfAbsent(name, () => arg);
    }
    return CacheControl(out);
  }

  /// Whether directive [name] is present.
  bool has(String name) => directives.containsKey(name);

  /// The non-negative integer value of [name] in seconds, or `null` when it is
  /// absent or malformed (a malformed delta is treated as absent).
  int? seconds(String name) {
    final v = directives[name];
    if (v == null) return null;
    final n = int.tryParse(v);
    return n == null || n < 0 ? null : n;
  }

  /// `no-store`.
  bool get noStore => has('no-store');

  /// `no-cache` (in a response: store, but revalidate before every reuse).
  bool get noCache => has('no-cache');

  /// `private` (with or without a field list).
  bool get isPrivate => has('private');

  /// `public`.
  bool get isPublic => has('public');

  /// `must-revalidate` or `proxy-revalidate` (a shared cache honours both).
  bool get mustRevalidate => has('must-revalidate') || has('proxy-revalidate');

  /// `only-if-cached` (request).
  bool get onlyIfCached => has('only-if-cached');
}

/// Parses an HTTP date (`Date`, `Expires`, `Last-Modified`), or `null`.
DateTime? parseHttpDate(String? value) {
  if (value == null) return null;
  try {
    return HttpDate.parse(value.trim());
  } on Object {
    return null;
  }
}

/// Formats [time] as an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`).
String formatHttpDate(DateTime time) => HttpDate.format(time);

/// Status codes this cache stores (RFC 9111 §3: those defined as heuristically
/// cacheable, minus `206`/`300`/`405`/`414`/`501`, which a tunnel's static
/// content never needs).
const Set<int> cacheableStatuses = {200, 203, 204, 301, 308, 404, 410};

/// The freshness lifetime a response grants a shared cache, or `null` when it
/// gives none: `s-maxage`, then `max-age`, then `Expires` − `Date`, then
/// [defaultTtl]. A response `no-cache` grants zero (always revalidate).
Duration? freshnessLifetime(
  List<HeaderField> headers, {
  Duration? defaultTtl,
  required DateTime responseTime,
}) {
  final cc = CacheControl.of(headers);
  if (cc.noCache) return Duration.zero;
  final s = cc.seconds('s-maxage') ?? cc.seconds('max-age');
  if (s != null) return Duration(seconds: s);
  final expires = headerValue(headers, 'expires');
  if (expires != null) {
    final at = parseHttpDate(expires);
    // An invalid Expires (e.g. "0") means already expired.
    if (at == null) return Duration.zero;
    final date = parseHttpDate(headerValue(headers, 'date')) ?? responseTime;
    final d = at.difference(date);
    return d.isNegative ? Duration.zero : d;
  }
  return defaultTtl;
}

/// Whether [headers] carries a validator usable for revalidation.
bool hasValidator(List<HeaderField> headers) =>
    headerValue(headers, 'etag') != null ||
    headerValue(headers, 'last-modified') != null;
