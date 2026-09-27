import 'dart:convert';

import '../../models/repeater.dart';
import '../../utils/public_key.dart';

/// How old the repeater list may be at connect before scope discovery wants
/// it fetched again (the server's `scopes_checked_at` rides on it).
const Duration kScopeRepeaterListMaxAge = Duration(hours: 1);

/// The server's scope stamp per repeater, keyed by the full upper-case
/// public key. Repeaters without a full key are left out.
Map<String, int?> scopeServerInfoMap(List<Repeater> repeaters) => {
      for (final r in repeaters)
        if (normalizePublicKey(r.hexId) case final key?) key: r.scopesCheckedAt,
    };

/// What the server list says about [keyHex]: whether it is on the list at
/// all, and when the server last had its scopes.
({bool onList, int? checkedAt}) scopeServerInfoFor(
    Map<String, int?> map, String keyHex) {
  final key = normalizePublicKey(keyHex);
  if (key == null || !map.containsKey(key)) {
    return (onList: false, checkedAt: null);
  }
  return (onList: true, checkedAt: map[key]);
}

/// Whether the connect-time repeater list refresh is due: scope discovery
/// is active and the list is missing or older than
/// [kScopeRepeaterListMaxAge].
bool scopeRepeaterRefreshDue(
    {required bool active, required DateTime? loadedAt, required DateTime now}) {
  if (!active) return false;
  if (loadedAt == null) return true;
  return now.difference(loadedAt) >= kScopeRepeaterListMaxAge;
}

/// Whether a repeater list fetched for [requestedZone] under
/// [requestedFilterKey] may still be applied: neither the zone nor the
/// radio preset moved while it was in flight.
bool scopeRepeaterRefreshStillCurrent({
  required String requestedZone,
  required String? requestedFilterKey,
  required String? currentZone,
  required String? currentFilterKey,
}) =>
    requestedZone == currentZone && requestedFilterKey == currentFilterKey;

/// Decodes a stored JSON object (a string or a map), or null for anything
/// else. Never throws.
Map<String, dynamic>? decodeScopeJsonMap(Object? raw) {
  try {
    final value = raw is String ? jsonDecode(raw) : raw;
    if (value is! Map) return null;
    return {
      for (final e in value.entries)
        if (e.key is String) e.key as String: e.value,
    };
  } catch (_) {
    return null;
  }
}
