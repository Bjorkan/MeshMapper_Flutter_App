import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// While the connected radio's contact table is full (a companion firmware
/// bug this connection has already hit), the Settings tile grows an extra
/// line, but only while connected to that radio.
void main() {
  test('connected with the flag set needs the note', () {
    expect(
        scopeDiscoveryContactsFull(connected: true, flagSet: true), isTrue);
  });

  test('connected with the flag clear needs no note', () {
    expect(
        scopeDiscoveryContactsFull(connected: true, flagSet: false), isFalse);
  });

  test('disconnected never needs the note, whatever the flag last read', () {
    expect(
        scopeDiscoveryContactsFull(connected: false, flagSet: true), isFalse);
  });
}
