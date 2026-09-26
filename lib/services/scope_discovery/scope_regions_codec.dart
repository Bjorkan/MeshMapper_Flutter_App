import 'dart:convert';
import 'dart:typed_data';
import '../meshcore/protocol_constants.dart';

/// A repeater holds at most 32 regions, plus `*`.
const int kMaxScopeEntries = 33;

/// `[regions][reply path len 0]`: the repeater answers zero-hop direct.
Uint8List buildRegionsRequest() =>
    Uint8List.fromList([AnonRequestTypes.regions, 0x00]);

/// Parses the body of a regions reply as the connection hands it over
/// (tag already removed): `[repeater clock 4][comma-separated names]`.
/// Returns null for a malformed answer, which the caller logs and never
/// uploads. Names are kept exactly as sent: scope names are
/// case-sensitive in firmware, so nothing is trimmed or lower-cased.
List<String>? parseRegionsReply(Uint8List data) {
  if (data.length < 4) return null;
  final body = data.sublist(4);
  if (body.isEmpty) return const <String>[];
  if (body.contains(0)) return null;
  final String text;
  try {
    text = utf8.decode(body); // allowMalformed defaults to false
  } on FormatException {
    return null;
  }
  final names = text.split(',');
  if (names.length > kMaxScopeEntries) return null;
  if (!names.every(isValidScopeToken)) return null;
  return names;
}

/// The server's (and firmware's) token rule for one scope name: exactly
/// `*`, or 1 to 30 bytes with no leading `#`, every byte one of `-`, `$`,
/// `#`, `0`-`9`, or at least `A`. The server rejects a whole SCOPES item
/// for one bad entry.
bool isValidScopeToken(String name) {
  if (name == '*') return true;
  final bytes = utf8.encode(name);
  if (bytes.isEmpty || bytes.length > 30) return false;
  if (bytes.first == 0x23) return false; // leading '#'
  for (final b in bytes) {
    final ok = b == 0x2D || b == 0x24 || b == 0x23 ||
        (b >= 0x30 && b <= 0x39) || b >= 0x41;
    if (!ok) return false;
  }
  return true;
}
