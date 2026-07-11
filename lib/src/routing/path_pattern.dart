/// A compiled path pattern with named parameters, for intra-service routing.
///
/// Segments of the form `<name>` capture a single path segment; a trailing
/// `<name|.*>` captures the remainder of the path (including slashes). Literal
/// segments must match exactly. Matching is anchored to the whole path.
///
/// ```dart
/// final p = PathPattern('/drives/<endpoint>/<name>/files/<path|.*>');
/// p.match('/drives/laptop/docs/files/a/b.txt');
/// //   => {endpoint: laptop, name: docs, path: a/b.txt}
/// p.match('/drives/laptop/docs');            // => null
/// ```
class PathPattern {
  /// The original pattern string.
  final String pattern;

  /// The parameter names in declaration order.
  final List<String> parameters;

  final RegExp _regExp;

  PathPattern._(this.pattern, this.parameters, this._regExp);

  /// Compiles [pattern].
  ///
  /// Throws [ArgumentError] if a `<...|.*>` tail parameter is not the last
  /// segment.
  factory PathPattern(String pattern) {
    final normalized = _normalize(pattern);
    final segments = normalized == '/'
        ? const <String>[]
        : normalized.substring(1).split('/');
    final params = <String>[];
    final buffer = StringBuffer('^');
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.startsWith('<') && segment.endsWith('>')) {
        final inner = segment.substring(1, segment.length - 1);
        final barIndex = inner.indexOf('|');
        if (barIndex >= 0) {
          final name = inner.substring(0, barIndex);
          final expr = inner.substring(barIndex + 1);
          if (expr == '.*') {
            if (i != segments.length - 1) {
              throw ArgumentError(
                'A "<$name|.*>" tail parameter must be the last segment: '
                '"$pattern"',
              );
            }
            params.add(name);
            // Optional "/remainder": the tail (and its slash) may be empty, so
            // "/files" and "/files/a/b" both match with path "" and "a/b".
            buffer.write('(?:/(?<$name>.*))?');
          } else {
            params.add(name);
            buffer.write('/(?<$name>$expr)');
          }
        } else {
          params.add(inner);
          buffer.write('/(?<$inner>[^/]+)');
        }
      } else {
        buffer.write('/${RegExp.escape(segment)}');
      }
    }
    buffer.write(r'$');
    return PathPattern._(pattern, params, RegExp(buffer.toString()));
  }

  /// Matches [path], returning captured parameters, or `null` if it does not
  /// match. The path is normalised (trailing slashes trimmed) before matching.
  Map<String, String>? match(String path) {
    final match = _regExp.firstMatch(_normalize(path));
    if (match == null) return null;
    return {for (final name in parameters) name: match.namedGroup(name) ?? ''};
  }

  /// Whether [path] matches this pattern.
  bool matches(String path) => _regExp.hasMatch(_normalize(path));

  @override
  String toString() => 'PathPattern($pattern)';

  static String _normalize(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
