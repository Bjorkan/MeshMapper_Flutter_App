import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';

void main() {
  test('every outcome reads in plain words', () {
    expect(ScopeLogOutcome.values.map((o) => o.label), [
      'Answered',
      'No response from repeater',
      'Sent as a flood by the radio',
      'Unreadable answer',
      'Radio error',
      'Not uploaded: hourly limit reached',
    ]);
  });

  test('an entry keeps the names exactly as received', () {
    final entry = ScopeLogEntry(
      timestamp: DateTime(2026, 9, 26, 10),
      latitude: 45.1,
      longitude: -75.2,
      repeaterId: 'AB',
      pubkeyHex: 'AB' * 32,
      outcome: ScopeLogOutcome.answered,
      scopes: const ['Ottawa', '*', 'west'],
    );
    expect(entry.scopes, ['Ottawa', '*', 'west']);
    expect(entry.outcome.label, 'Answered');
    final empty = ScopeLogEntry(
      timestamp: DateTime(2026, 9, 26, 10),
      latitude: 0,
      longitude: 0,
      repeaterId: 'CD',
      pubkeyHex: 'CD',
      outcome: ScopeLogOutcome.noResponse,
    );
    expect(empty.scopes, isNull);
  });
}
