import 'dart:async';

import '../../utils/debug_logger_io.dart';
import '../../utils/public_key.dart';

/// Whether a repeater's scopes should be asked again right now.
///
/// Reads two independent signals, and answers due only when both of them
/// call for a fresh ask:
///
/// - Rule 1, the server side: the server's own `scopesCheckedAt` for this
///   repeater. [onServerList] false (no list at all: offline, not loaded
///   yet) always counts as due on this rule.
/// - Rule 2, the phone side: this phone's own cached [phone] answer, if any.
///
/// [persistPending] is read before either rule: while an earlier answer for
/// this same repeater is still being written (Task 6's detached
/// persistence), the repeater is never due, whatever the two rules would
/// otherwise say.
bool isScopeQueryDue({
  required bool onServerList,
  required int? serverCheckedAt,
  required ScopeCacheEntry? phone,
  required bool persistPending,
  required int nowSec,
  required int refreshDays,
}) {
  if (persistPending) return false;
  final refreshSec = refreshDays * 86400;
  final rule1 = !onServerList ||
      serverCheckedAt == null ||
      nowSec - serverCheckedAt >= refreshSec;
  final answeredAt = phone?.answeredAt;
  final rule2 = answeredAt == null || nowSec - answeredAt >= refreshSec;
  return rule1 && rule2;
}

/// This phone's own cached answer for one repeater.
///
/// There are no attempt stamps: a request that got no answer records
/// nothing here, so that repeater reads as due again immediately (ruling 4).
class ScopeCacheEntry {
  /// When this phone last got an answer from the repeater (Unix seconds).
  final int? answeredAt;

  const ScopeCacheEntry({this.answeredAt});
}

/// The phone-side scope answer cache: the secondary guard behind the
/// server's own `scopes_checked_at`. The server already stops re-asks of
/// registered repeaters fleet-wide, and the hourly budget bounds how many
/// answers a phone can hold in the first place, so this cache's own
/// retention can be bounded on purpose (server ruling, round 2) without
/// costing more than an occasional extra zero-hop request.
///
/// Keys are the repeater's full public key, normalized with
/// [normalizePublicKey]; anything that does not normalize is never stored
/// and never returned.
class ScopeQueryCache {
  /// Retention is bounded: once more than this many answers are held, the
  /// oldest are evicted regardless of how fresh the interval says they
  /// still are.
  static const int maxEntries = 20000;

  /// The bound Task 6's runner holds `pendingPersist` to. Named here so both
  /// sides agree on the number; enforcing it (never evicting past it) is the
  /// runner's job, not this cache's.
  static const int maxPendingPersist = 32;

  final Map<String, ScopeCacheEntry> _entries;

  /// Repeater keys whose answer is still being written to disk (Task 6's
  /// detached persistence). Memory only: never read by [toJson] or
  /// populated by [fromJson].
  final Set<String> pendingPersist = <String>{};

  ScopeQueryCache._(this._entries);

  /// Builds a cache from a stored JSON map. Tolerates any junk: a non-map
  /// root, a key that does not normalize to a full public key, or a value
  /// that is not a map with an int (or num) `answeredAt` is simply skipped.
  factory ScopeQueryCache.fromJson(Map<String, dynamic>? json) {
    final entries = <String, ScopeCacheEntry>{};
    if (json != null) {
      json.forEach((rawKey, rawValue) {
        final key = normalizePublicKey(rawKey);
        if (key == null) return;
        if (rawValue is! Map) return;
        final rawAnsweredAt = rawValue['answeredAt'];
        final answeredAt = rawAnsweredAt is int
            ? rawAnsweredAt
            : rawAnsweredAt is num
                ? rawAnsweredAt.toInt()
                : null;
        if (answeredAt == null) return;
        entries[key] = ScopeCacheEntry(answeredAt: answeredAt);
      });
    }
    return ScopeQueryCache._(entries);
  }

  /// Serializes the answer stamps only. [pendingPersist] never rides along:
  /// it names work in flight for this launch, not a durable fact.
  Map<String, dynamic> toJson() => {
        for (final entry in _entries.entries)
          entry.key: {'answeredAt': entry.value.answeredAt},
      };

  /// This repeater's cached answer, or null when it has none or [keyHex]
  /// does not normalize to a full public key.
  ScopeCacheEntry? operator [](String keyHex) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return null;
    return _entries[key];
  }

  /// Records that the repeater answered at [nowSec]. A no-op when [keyHex]
  /// does not normalize to a full public key.
  void recordAnswer(String keyHex, int nowSec) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return;
    _entries[key] = ScopeCacheEntry(answeredAt: nowSec);
  }

  /// Drops answers the interval no longer needs, then, only if still over
  /// [maxEntries], evicts the oldest remaining answers to fit.
  ///
  /// Retention follows the interval in force, never a fixed age (the server
  /// allows intervals up to 99999 days): an answer stops blocking a re-ask
  /// once it is older than [refreshDays], so removing it at that point
  /// cannot change any decision [isScopeQueryDue] would make under the same
  /// interval. If the interval later grows, a stamp pruned under a shorter
  /// interval is gone, so that repeater can be asked early once; a known,
  /// accepted edge.
  void prune({required int nowSec, required int refreshDays}) {
    final refreshSec = refreshDays * 86400;
    _entries.removeWhere((_, entry) {
      final answeredAt = entry.answeredAt;
      return answeredAt != null && nowSec - answeredAt >= refreshSec;
    });
    final overflow = _entries.length - maxEntries;
    if (overflow <= 0) return;
    final oldestFirst = _entries.entries.toList()
      ..sort((a, b) =>
          (a.value.answeredAt ?? 0).compareTo(b.value.answeredAt ?? 0));
    for (var i = 0; i < overflow; i++) {
      _entries.remove(oldestFirst[i].key);
    }
    debugLog('[SCOPES] Evicted $overflow scope cache '
        '${overflow == 1 ? 'entry' : 'entries'} over the $maxEntries cap');
  }
}

/// The per-device-hour cap on `SCOPES` uploads: [perHour] per hour of the
/// answer's own timestamp, matching the server's own cap on the item's
/// timestamp. [deviceKey] is the connected radio's public key, or the
/// session id when there is none (ruling 5); there is no session reset, so
/// the same radio under a new session id is still capped by its own key.
///
/// Restart-safe: [tryConsume] reserves synchronously in memory, so the
/// caller never waits on storage to know whether it may proceed.
/// [persistReservation] then writes that reservation durably, serialized
/// through one internal chain so two answers persisting at once both land
/// instead of one clobbering the other's count.
class ScopeHourlyBudget {
  static const int perHour = 60;

  final Future<void> Function(Map<String, dynamic> json) _save;
  final Map<String, int> _counts = {};

  /// Buckets (`deviceKey|hour`) with a [persistReservation] call still
  /// running: added when that call starts, removed only when its own save
  /// settles (success or failure), whatever turn it happens to be taking on
  /// the write chain. A bucket in here is never dropped as stale, however
  /// old it has become in the meantime.
  final Set<String> _inFlightBuckets = {};

  Future<void> _chain = Future<void>.value();

  ScopeHourlyBudget(
      {required Future<void> Function(Map<String, dynamic> json) save})
      : _save = save;

  /// Loads a persisted budget. Tolerates junk like [ScopeQueryCache] does: a
  /// non-map root, a bucket key with no hour suffix, or a non-numeric count
  /// is skipped. Buckets older than the previous hour (relative to
  /// [nowSec]) are dropped on load, since nothing can be in flight for a
  /// budget that has not run yet.
  factory ScopeHourlyBudget.fromJson(
    Map<String, dynamic>? json, {
    required Future<void> Function(Map<String, dynamic> json) save,
    required int nowSec,
  }) {
    final budget = ScopeHourlyBudget(save: save);
    if (json != null) {
      final currentHour = nowSec ~/ 3600;
      json.forEach((bucketKey, rawCount) {
        final count = rawCount is int
            ? rawCount
            : rawCount is num
                ? rawCount.toInt()
                : null;
        if (count == null) return;
        final hour = _hourOf(bucketKey);
        if (hour == null) return;
        if (hour < currentHour - 1) return;
        budget._counts[bucketKey] = count;
      });
    }
    return budget;
  }

  /// The raw bucket counts, exactly as [persistReservation] would save them
  /// right now. Mainly useful for tests and diagnostics; the durable write
  /// path is [persistReservation], not this.
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_counts);

  /// True while [deviceKey]'s bucket for the hour [nowSec] falls in still
  /// has room. Read-only: reserves nothing.
  bool canAsk(String deviceKey, int nowSec) =>
      (_counts[_bucketKey(deviceKey, nowSec ~/ 3600)] ?? 0) < perHour;

  /// Reserves one slot in [deviceKey]'s bucket for the hour [answerSec]
  /// falls in, synchronously. False when that hour is already full.
  bool tryConsume(String deviceKey, int answerSec) {
    final key = _bucketKey(deviceKey, answerSec ~/ 3600);
    final count = _counts[key] ?? 0;
    if (count >= perHour) return false;
    _counts[key] = count + 1;
    return true;
  }

  /// Durably persists the reservation [tryConsume] made for [deviceKey]'s
  /// [hour] bucket.
  ///
  /// The bucket is marked in flight for the life of this call (from here
  /// until the returned future settles, not merely for as long as this
  /// call's own turn on the write chain takes), so a later call's
  /// stale-bucket drop never removes an answer whose own persistence has
  /// not finished, however old that bucket has become in the meantime.
  ///
  /// Resolves false when [save] throws; the in-memory reservation stays
  /// counted regardless, which is conservative: a failed write drops the
  /// answer, it never grants an extra slot.
  Future<bool> persistReservation(String deviceKey, int hour) {
    final bucketKey = _bucketKey(deviceKey, hour);
    _inFlightBuckets.add(bucketKey);
    _dropStale(hour);
    final result = Completer<bool>();
    _chain = _chain.then((_) async {
      try {
        await _save(Map<String, dynamic>.from(_counts));
        result.complete(true);
      } catch (e) {
        debugWarn('[SCOPES] Failed to persist scope hour budget: $e');
        result.complete(false);
      } finally {
        _inFlightBuckets.remove(bucketKey);
      }
    });
    return result.future;
  }

  /// Drops buckets older than the previous hour relative to [currentHour],
  /// except one still named in [_inFlightBuckets].
  void _dropStale(int currentHour) {
    _counts.removeWhere((key, _) {
      if (_inFlightBuckets.contains(key)) return false;
      final hour = _hourOf(key);
      return hour != null && hour < currentHour - 1;
    });
  }

  static String _bucketKey(String deviceKey, int hour) => '$deviceKey|$hour';

  static int? _hourOf(String bucketKey) {
    final i = bucketKey.lastIndexOf('|');
    if (i < 0) return null;
    return int.tryParse(bucketKey.substring(i + 1));
  }
}
