import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../forwarded_headers.dart';
import '../http_stream_parser.dart';
import 'cache_control.dart';

/// How one [HttpCache] behaves and how large it may grow.
@immutable
class HttpCacheOptions {
  /// The most bytes (heads + bodies + per-entry overhead) this cache holds.
  final int maxBytes;

  /// The largest single response stored; bigger ones are relayed, not kept.
  final int maxEntryBytes;

  /// Also store `Cache-Control: private` responses. They are then shared by
  /// every consumer of this cache, so responses that set a cookie and requests
  /// that carry `Authorization` stay uncached regardless.
  final bool cachePrivate;

  /// The freshness lifetime given to a response that states none (no
  /// `max-age`/`s-maxage`/`Expires`). `null` leaves such responses uncached.
  final Duration? defaultTtl;

  /// Creates cache options.
  const HttpCacheOptions({
    required this.maxBytes,
    this.maxEntryBytes = 8 * 1024 * 1024,
    this.cachePrivate = false,
    this.defaultTtl,
  });
}

/// A memory budget shared by several [HttpCache]s: when their combined size
/// exceeds [maxBytes], the least recently used entry across *all* of them is
/// evicted, so one busy cache cannot starve a host of memory.
class HttpCacheBudget {
  /// The most bytes all attached caches may hold together.
  final int maxBytes;

  /// Entry → (owning cache, size counted), oldest first.
  final LinkedHashMap<HttpCacheEntry, (HttpCache, int)> _lru = LinkedHashMap();
  int _used = 0;

  /// Creates a budget of [maxBytes].
  HttpCacheBudget(this.maxBytes);

  /// The bytes currently held by all attached caches.
  int get usedBytes => _used;

  void _add(HttpCacheEntry e, HttpCache owner) {
    _remove(e);
    _lru[e] = (owner, e.size);
    _used += e.size;
    while (_used > maxBytes && _lru.isNotEmpty) {
      final oldest = _lru.keys.first;
      _lru[oldest]!.$1._remove(oldest);
    }
  }

  void _touch(HttpCacheEntry e) {
    final v = _lru.remove(e);
    if (v != null) _lru[e] = v;
  }

  void _remove(HttpCacheEntry e) {
    final v = _lru.remove(e);
    if (v != null) _used -= v.$2;
  }
}

/// One stored response: its head and its body exactly as framed on the wire.
class HttpCacheEntry {
  /// The primary cache key ([HttpCache.keyFor]).
  final String key;

  /// The stored response head (hop-by-hop fields, `Age` and `X-Cache`
  /// removed). Replaced when a `304` refreshes the entry.
  HttpResponseHead head;

  /// The body bytes as received (chunk framing and trailers included).
  final Uint8List body;

  /// The request's values of the response's `Vary` fields, lower-cased name →
  /// normalized value (`''` when the request lacked it).
  final Map<String, String> vary;

  /// When the response (or its latest `304`) was received.
  DateTime responseTime;

  /// The age the response already had on arrival, in seconds.
  int initialAge;

  /// How long the entry is fresh, measured from its age.
  Duration lifetime;

  int _headBytes;

  HttpCacheEntry._({
    required this.key,
    required this.head,
    required this.body,
    required this.vary,
    required this.responseTime,
    required this.initialAge,
    required this.lifetime,
  }) : _headBytes = encodeHttpResponseHead(head).length;

  /// Fixed per-entry bookkeeping overhead counted against the budget.
  static const int overheadBytes = 256;

  /// The bytes this entry counts against its cache and budget.
  int get size => _headBytes + body.length + overheadBytes;

  /// The entry's current age (RFC 9111 §4.2.3).
  Duration age(DateTime now) {
    final resident = now.difference(responseTime);
    return Duration(seconds: initialAge) +
        (resident.isNegative ? Duration.zero : resident);
  }

  /// Whether the entry is fresh at [now].
  bool isFresh(DateTime now) => age(now) < lifetime;

  /// Whether the stored response forbids serving it stale.
  bool get mustRevalidate => CacheControl.of(head.headers).mustRevalidate;

  /// Whether the stored response can be revalidated.
  bool get hasValidator => _hasValidator(head.headers);
}

bool _hasValidator(List<HeaderField> headers) => hasValidator(headers);

/// Counters for one [HttpCache].
@immutable
class HttpCacheStats {
  /// Stored entries.
  final int entries;

  /// Bytes held.
  final int bytes;

  /// Requests answered from a fresh entry.
  final int hits;

  /// Cacheable requests that had to go to the origin.
  final int misses;

  /// Stale entries confirmed by a `304`.
  final int revalidated;

  /// Requests that were not cacheable (method, `Authorization`, body, …).
  final int bypassed;

  /// Creates stats.
  const HttpCacheStats({
    this.entries = 0,
    this.bytes = 0,
    this.hits = 0,
    this.misses = 0,
    this.revalidated = 0,
    this.bypassed = 0,
  });
}

/// The outcome of [HttpCache.lookup] for one request.
sealed class CacheLookup {
  const CacheLookup();
}

/// The request may not use the cache at all; forward it and store nothing.
final class CacheBypass extends CacheLookup {
  /// Why (for diagnostics), e.g. `method`, `authorization`, `no-store`.
  final String reason;

  /// Creates a bypass outcome.
  const CacheBypass(this.reason);
}

/// No usable entry; forward the request and offer the response for storage.
final class CacheMiss extends CacheLookup {
  /// A stale entry that could not be revalidated (no validator), kept so it
  /// can still be served under `stale-if-error` if the origin fails.
  final HttpCacheEntry? stale;

  /// Creates a miss outcome.
  const CacheMiss({this.stale});
}

/// Serve [entry] without contacting the origin.
final class CacheHit extends CacheLookup {
  /// The entry to serve.
  final HttpCacheEntry entry;

  /// Creates a hit outcome.
  const CacheHit(this.entry);
}

/// [entry] is stale (or the request demands it): ask the origin with its
/// validators and serve it if the origin answers `304`.
final class CacheRevalidate extends CacheLookup {
  /// The entry to revalidate.
  final HttpCacheEntry entry;

  /// Creates a revalidate outcome.
  const CacheRevalidate(this.entry);
}

/// The request said `only-if-cached` and nothing usable is stored: answer
/// `504 Gateway Timeout` (RFC 9111 §5.2.1.7).
final class CacheUnsatisfiable extends CacheLookup {
  /// Creates an unsatisfiable outcome.
  const CacheUnsatisfiable();
}

/// An in-memory, LRU, shared HTTP cache following RFC 9111.
///
/// It decides ([lookup]) and stores ([store], [refresh]); moving bytes is the
/// job of a relay such as `CachingHttpRelay`. Only `GET` (and `HEAD`, served
/// from `GET` entries) of HTTP/1.1 requests without `Authorization`, `Range` or
/// a body participate; see [whyNotStorable] for what is kept.
class HttpCache {
  /// The cache's behaviour and limits.
  final HttpCacheOptions options;

  /// The shared budget this cache also counts against, if any.
  final HttpCacheBudget? budget;

  /// The clock.
  final DateTime Function() now;

  final Map<String, List<HttpCacheEntry>> _byKey = {};
  final LinkedHashSet<HttpCacheEntry> _lru = LinkedHashSet();
  int _bytes = 0;
  int _hits = 0;
  int _misses = 0;
  int _revalidated = 0;
  int _bypassed = 0;

  /// Creates a cache with [options], optionally sharing [budget].
  HttpCache(this.options, {this.budget, DateTime Function()? now})
    : now = now ?? DateTime.now;

  /// The current counters.
  HttpCacheStats get stats => HttpCacheStats(
    entries: _lru.length,
    bytes: _bytes,
    hits: _hits,
    misses: _misses,
    revalidated: _revalidated,
    bypassed: _bypassed,
  );

  /// Counts a served hit.
  void recordHit() => _hits++;

  /// Counts a miss.
  void recordMiss() => _misses++;

  /// Counts a successful revalidation.
  void recordRevalidated() => _revalidated++;

  /// Counts a bypassed request.
  void recordBypass() => _bypassed++;

  /// The primary key for [request]: lower-cased `Host` + request target.
  /// `HEAD` and `GET` share keys so a `HEAD` can be answered from a `GET`.
  static String keyFor(HttpRequestHead request) {
    final host = (headerValue(request.headers, 'host') ?? '').toLowerCase();
    return '$host ${request.target}';
  }

  /// Decides how [request] uses the cache at [at] (default: [now]).
  CacheLookup lookup(HttpRequestHead request, {DateTime? at}) {
    final reason = _bypassReason(request);
    if (reason != null) return CacheBypass(reason);
    final t = at ?? now();
    final cc = _requestCacheControl(request.headers);
    final entry = _find(request);
    if (entry == null) {
      return cc.onlyIfCached ? const CacheUnsatisfiable() : const CacheMiss();
    }
    if (_acceptable(entry, cc, t)) return CacheHit(entry);
    if (cc.onlyIfCached) return const CacheUnsatisfiable();
    return entry.hasValidator
        ? CacheRevalidate(entry)
        : CacheMiss(stale: entry);
  }

  /// Whether stale [entry] may answer [request] because the origin failed
  /// (RFC 5861 `stale-if-error=N`, in the response or the request): it must be
  /// at most N seconds past its freshness lifetime.
  bool canServeStaleOnError(
    HttpCacheEntry entry,
    HttpRequestHead request, {
    DateTime? at,
  }) {
    final window =
        CacheControl.of(request.headers).seconds('stale-if-error') ??
        CacheControl.of(entry.head.headers).seconds('stale-if-error');
    if (window == null) return false;
    final staleness = entry.age(at ?? now()) - entry.lifetime;
    return staleness <= Duration(seconds: window);
  }

  String? _bypassReason(HttpRequestHead r) {
    if (r.method != 'GET' && r.method != 'HEAD') return 'method';
    if (r.version != '1.1') return 'http/1.0';
    if (headerValue(r.headers, 'authorization') != null) {
      return 'authorization';
    }
    if (headerValue(r.headers, 'range') != null) return 'range';
    if (headerValue(r.headers, 'upgrade') != null) return 'upgrade';
    if (headerTokens(r.headers, 'transfer-encoding').isNotEmpty ||
        (int.tryParse(headerValue(r.headers, 'content-length') ?? '0') ?? 1) !=
            0) {
      return 'body';
    }
    if (CacheControl.of(r.headers).noStore) return 'no-store';
    return null;
  }

  /// The request's directives, with `Pragma: no-cache` honoured when it sends
  /// no `Cache-Control` (RFC 9111 §5.4).
  static CacheControl _requestCacheControl(List<HeaderField> headers) {
    final cc = CacheControl.of(headers);
    if (cc.directives.isEmpty &&
        headerTokens(headers, 'pragma').contains('no-cache')) {
      return const CacheControl({'no-cache': null});
    }
    return cc;
  }

  bool _acceptable(HttpCacheEntry e, CacheControl req, DateTime t) {
    if (CacheControl.of(e.head.headers).noCache || req.noCache) return false;
    final age = e.age(t);
    final maxAge = req.seconds('max-age');
    if (maxAge != null && age > Duration(seconds: maxAge)) return false;
    final minFresh = req.seconds('min-fresh');
    if (minFresh != null && e.lifetime - age < Duration(seconds: minFresh)) {
      return false;
    }
    if (age < e.lifetime) return true;
    // Stale: only with the request's max-stale, never past must-revalidate.
    if (!req.has('max-stale') || e.mustRevalidate) return false;
    final maxStale = req.seconds('max-stale');
    return maxStale == null || age - e.lifetime <= Duration(seconds: maxStale);
  }

  HttpCacheEntry? _find(HttpRequestHead request) {
    final variants = _byKey[keyFor(request)];
    if (variants == null) return null;
    for (final e in variants) {
      if (_varyMatches(e, request.headers)) {
        _touch(e);
        return e;
      }
    }
    return null;
  }

  static bool _varyMatches(HttpCacheEntry e, List<HeaderField> headers) {
    for (final entry in e.vary.entries) {
      if (_normalized(headerValue(headers, entry.key)) != entry.value) {
        return false;
      }
    }
    return true;
  }

  static String _normalized(String? v) => v == null
      ? ''
      : v.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).join(',');

  /// Why [response] to [request] may not be stored, or `null` when it may.
  ///
  /// Stored: `GET`s answered with a status in [cacheableStatuses] whose length
  /// is known (`Content-Length`, chunked, or no body), that are not
  /// `no-store`, not `private` (unless [HttpCacheOptions.cachePrivate]), set no
  /// cookie, do not `Vary: *`, have a freshness lifetime (explicit, or the
  /// default TTL) — zero only with a validator — and fit
  /// [HttpCacheOptions.maxEntryBytes].
  String? whyNotStorable(
    HttpRequestHead request,
    HttpResponseHead response, {
    required int bodyBytes,
    DateTime? responseTime,
  }) {
    final bypass = _bypassReason(request);
    if (bypass != null) return bypass;
    if (request.method != 'GET') return 'method';
    if (!cacheableStatuses.contains(response.status)) return 'status';
    final cc = CacheControl.of(response.headers);
    if (cc.noStore) return 'no-store';
    if (cc.isPrivate && !options.cachePrivate) return 'private';
    if (headerValue(response.headers, 'set-cookie') != null) {
      return 'set-cookie';
    }
    if (headerTokens(response.headers, 'vary').contains('*')) return 'vary';
    final framed =
        response.status == 204 ||
        headerTokens(response.headers, 'transfer-encoding').lastOrNull ==
            'chunked' ||
        headerValue(response.headers, 'content-length') != null;
    if (!framed) return 'length';
    final lifetime = freshnessLifetime(
      response.headers,
      defaultTtl: options.defaultTtl,
      responseTime: responseTime ?? now(),
    );
    if (lifetime == null) return 'no-freshness';
    if (lifetime == Duration.zero && !hasValidator(response.headers)) {
      return 'no-freshness';
    }
    final size =
        encodeHttpResponseHead(_storedHead(response)).length +
        bodyBytes +
        HttpCacheEntry.overheadBytes;
    if (size > options.maxEntryBytes || size > options.maxBytes) {
      return 'too-large';
    }
    return null;
  }

  /// Stores [response] (with its raw [body]) to [request], if storable.
  /// [requestTime] is when the request was forwarded, [responseTime] when the
  /// response head arrived. Returns the new entry, or `null`.
  HttpCacheEntry? store({
    required HttpRequestHead request,
    required HttpResponseHead response,
    required Uint8List body,
    required DateTime requestTime,
    required DateTime responseTime,
  }) {
    if (whyNotStorable(
          request,
          response,
          bodyBytes: body.length,
          responseTime: responseTime,
        ) !=
        null) {
      return null;
    }
    final names = headerTokens(response.headers, 'vary');
    final vary = {
      for (final n in names) n: _normalized(headerValue(request.headers, n)),
    };
    final entry = HttpCacheEntry._(
      key: keyFor(request),
      head: _storedHead(response),
      body: body,
      vary: vary,
      responseTime: responseTime,
      initialAge: _initialAge(response.headers, requestTime, responseTime),
      lifetime: freshnessLifetime(
        response.headers,
        defaultTtl: options.defaultTtl,
        responseTime: responseTime,
      )!,
    );
    // A new response replaces the variant it matches.
    final variants = _byKey[entry.key];
    if (variants != null) {
      for (final old in [...variants]) {
        if (_sameVary(old.vary, vary)) _remove(old);
      }
    }
    (_byKey[entry.key] ??= []).add(entry);
    _lru.add(entry);
    _bytes += entry.size;
    budget?._add(entry, this);
    while (_bytes > options.maxBytes && _lru.isNotEmpty) {
      _remove(_lru.first);
    }
    return _lru.contains(entry) ? entry : null;
  }

  /// Whether [name] describes (or frames) the stored body rather than the
  /// response as a whole: every `Content-*` field except `Content-Location`,
  /// plus `Transfer-Encoding` and `Trailer`. A `304` never updates these.
  static bool isRepresentationField(String name) {
    final n = name.toLowerCase();
    if (n == 'transfer-encoding' || n == 'trailer') return true;
    return n.startsWith('content-') && n != 'content-location';
  }

  static bool _sameVary(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Refreshes [entry] from a `304 Not Modified` [notModified] (RFC 9111
  /// §4.3.4): its fields replace the stored ones and freshness restarts. An
  /// update that makes the entry `no-store` drops it.
  ///
  /// A `304` confirms the stored body, so fields that describe that body are
  /// never taken from it ([isRepresentationField]): some servers send
  /// defaults there — Dart's `HttpServer`, for one, puts
  /// `Content-Type: text/plain; charset=utf-8` on every `304` — which would
  /// otherwise relabel a cached `text/html` page. `Set-Cookie` is never
  /// stored either: it belongs to the one client whose request triggered the
  /// revalidation (the relay passes it to that client only), not to everyone
  /// the entry is later served to.
  void refresh(
    HttpCacheEntry entry,
    HttpResponseHead notModified, {
    required DateTime requestTime,
    required DateTime responseTime,
  }) {
    if (!_lru.contains(entry)) return;
    final updates = {
      for (final h in _storedHead(notModified).headers)
        if (!isRepresentationField(h.name) &&
            h.name.toLowerCase() != 'set-cookie')
          h.name.toLowerCase(),
    };
    final merged = <HeaderField>[
      for (final h in entry.head.headers)
        if (!updates.contains(h.name.toLowerCase())) h,
      for (final h in _storedHead(notModified).headers)
        if (updates.contains(h.name.toLowerCase())) h,
    ];
    if (CacheControl.of(merged).noStore) {
      _remove(entry);
      return;
    }
    final before = entry.size;
    entry
      ..head = (
        version: entry.head.version,
        status: entry.head.status,
        reason: entry.head.reason,
        headers: merged,
      )
      .._headBytes = encodeHttpResponseHead(entry.head).length
      ..responseTime = responseTime
      ..initialAge = _initialAge(notModified.headers, requestTime, responseTime)
      ..lifetime =
          freshnessLifetime(
            merged,
            defaultTtl: options.defaultTtl,
            responseTime: responseTime,
          ) ??
          Duration.zero;
    _bytes += entry.size - before;
    // Re-count the new size against the shared budget (may evict others).
    budget?._add(entry, this);
    _touch(entry);
  }

  /// Drops every variant stored under [key].
  void invalidate(String key) {
    final variants = _byKey[key];
    if (variants == null) return;
    for (final e in [...variants]) {
      _remove(e);
    }
  }

  /// Drops every entry (e.g. when the owning tunnel closes).
  void clear() {
    for (final e in [..._lru]) {
      _remove(e);
    }
  }

  void _touch(HttpCacheEntry e) {
    if (_lru.remove(e)) _lru.add(e);
    budget?._touch(e);
  }

  void _remove(HttpCacheEntry e) {
    if (!_lru.remove(e)) return;
    _bytes -= e.size;
    final variants = _byKey[e.key];
    variants?.remove(e);
    if (variants != null && variants.isEmpty) _byKey.remove(e.key);
    budget?._remove(e);
  }

  /// The head as stored: hop-by-hop fields (and those `Connection` names),
  /// `Age` and `X-Cache` removed.
  static HttpResponseHead _storedHead(HttpResponseHead h) {
    final drop = {
      'connection',
      'keep-alive',
      'proxy-connection',
      'upgrade',
      'te',
      'age',
      'x-cache',
      ...headerTokens(h.headers, 'connection'),
    };
    return (
      version: h.version,
      status: h.status,
      reason: h.reason,
      headers: [
        for (final f in h.headers)
          if (!drop.contains(f.name.toLowerCase())) f,
      ],
    );
  }

  /// RFC 9111 §4.2.3 `corrected_initial_age`, in seconds.
  static int _initialAge(
    List<HeaderField> headers,
    DateTime requestTime,
    DateTime responseTime,
  ) {
    final date = parseHttpDate(headerValue(headers, 'date'));
    final apparent = date == null
        ? 0
        : responseTime.difference(date).inSeconds.clamp(0, 1 << 31);
    final ageValue = int.tryParse(headerValue(headers, 'age') ?? '') ?? 0;
    final delay = responseTime
        .difference(requestTime)
        .inSeconds
        .clamp(0, 1 << 31);
    final corrected = ageValue + delay;
    return apparent > corrected ? apparent : corrected;
  }
}
