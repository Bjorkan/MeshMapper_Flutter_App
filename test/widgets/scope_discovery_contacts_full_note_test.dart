import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/widgets/scope_discovery_firmware_note.dart';

const _noteText = "Your radio's contact list is full, so only repeaters "
    'saved as contacts can be asked. Companion firmware v1.17 or newer '
    'fixes this, or remove some contacts.';

void main() {
  Future<void> pump(WidgetTester tester, bool show) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScopeDiscoveryContactsFullNote(show: show)),
        ),
      );

  testWidgets('connected with the flag set shows the line', (tester) async {
    await pump(
        tester, scopeDiscoveryContactsFull(connected: true, flagSet: true));
    expect(find.text(_noteText), findsOneWidget);
  });

  testWidgets('connected with the flag clear shows nothing', (tester) async {
    await pump(
        tester, scopeDiscoveryContactsFull(connected: true, flagSet: false));
    expect(find.text(_noteText), findsNothing);
  });

  testWidgets('disconnected shows nothing', (tester) async {
    await pump(
        tester, scopeDiscoveryContactsFull(connected: false, flagSet: true));
    expect(find.text(_noteText), findsNothing);
  });
}
