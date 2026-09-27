import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/log_entry.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';
import 'package:mesh_mapper/screens/log_screen.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';

/// The private `_AllPingsTab` needs a live `AppStateProvider`, which no test
/// in this suite can build (see `test/widgets/ping_controls_scope_badge_test.dart`).
/// The SCP pieces below are exercised the same way that file exercises the
/// "Scopes" badge: pump the real, provider-free widgets `LogFilterSegment`
/// and `ScopeLogCard` in isolation, and unit-test the pure filter/search
/// functions those widgets are wired to inside `_AllPingsTabState`.
ScopeLogEntry _entry({
  DateTime? timestamp,
  String repeaterId = 'AB',
  ScopeLogOutcome outcome = ScopeLogOutcome.answered,
  List<String>? scopes,
}) {
  return ScopeLogEntry(
    timestamp: timestamp ?? DateTime(2026, 9, 26, 9, 4, 7),
    latitude: 45.1,
    longitude: -75.2,
    repeaterId: repeaterId,
    pubkeyHex: repeaterId * 32,
    outcome: outcome,
    scopes: scopes,
  );
}

void main() {
  group('LogFilterSegment (SCP)', () {
    testWidgets('renders the SCP label and a count pill', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 12,
                color: PingColors.scopes,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));

      expect(find.text('SCP'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('tapping calls onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 3,
                color: PingColors.scopes,
                active: false,
                onTap: () => tapped = true,
              ),
            ],
          ),
        ),
      ));

      await tester.tap(find.text('SCP'));
      expect(tapped, isTrue);
    });

    testWidgets('a count above 99 caps the pill at 99+', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 140,
                color: PingColors.scopes,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('no pill shows when the count is zero', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 0,
                color: PingColors.scopes,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));

      expect(find.text('0'), findsNothing);
    });
  });

  group('filterUnifiedPingLog', () {
    test('toggling scopes off hides scope entries, keeping the rest', () {
      final scope = _entry();
      final scopeUnified = UnifiedPingLogEntry(
          type: PingLogType.scopes, timestamp: scope.timestamp, entry: scope);
      final tx = TxLogEntry(
        timestamp: DateTime(2026, 9, 26, 10),
        latitude: 45.1,
        longitude: -75.2,
        power: 0.3,
        events: const [],
      );
      final txUnified = UnifiedPingLogEntry(
          type: PingLogType.tx, timestamp: tx.timestamp, entry: tx);
      final all = [scopeUnified, txUnified];

      const everyType = {
        PingLogType.tx,
        PingLogType.rx,
        PingLogType.disc,
        PingLogType.trace,
        PingLogType.scopes,
      };
      expect(filterUnifiedPingLog(all, everyType), all);

      const withoutScopes = {
        PingLogType.tx,
        PingLogType.rx,
        PingLogType.disc,
        PingLogType.trace,
      };
      expect(filterUnifiedPingLog(all, withoutScopes), [txUnified]);
    });
  });

  group('scopeEntryMatchesSearch', () {
    test('an empty query matches everything', () {
      expect(scopeEntryMatchesSearch(_entry(), ''), isTrue);
    });

    test('matches the repeater id, case-insensitively', () {
      expect(scopeEntryMatchesSearch(_entry(repeaterId: 'AB'), 'ab'), isTrue);
    });

    test('matches a scope name, case-sensitively', () {
      final entry = _entry(scopes: const ['Ottawa', 'west']);
      expect(scopeEntryMatchesSearch(entry, 'Ottawa'), isTrue);
      expect(scopeEntryMatchesSearch(entry, 'ottawa'), isFalse);
    });

    test('matches the outcome words, case-insensitively', () {
      final entry = _entry(outcome: ScopeLogOutcome.noResponse);
      expect(scopeEntryMatchesSearch(entry, 'no response'), isTrue);
    });

    test('no match falls through to false', () {
      expect(scopeEntryMatchesSearch(_entry(), 'nowhere'), isFalse);
    });
  });

  group('ScopeLogCard', () {
    testWidgets('shows the SCP badge, time, location and repeater id',
        (tester) async {
      final entry = _entry(scopes: const ['Ottawa']);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('SCP'), findsOneWidget);
      expect(find.text(entry.timeString), findsOneWidget);
      expect(find.text(entry.locationString), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
    });

    testWidgets('an answered card shows its scope names exactly, case kept',
        (tester) async {
      final entry = _entry(scopes: const ['Ottawa', '*', 'west']);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('Answered'), findsOneWidget);
      expect(find.text('Ottawa'), findsOneWidget);
      expect(find.text('*'), findsOneWidget);
      expect(find.text('west'), findsOneWidget);
      expect(find.text('Carries no scopes'), findsNothing);
    });

    testWidgets('an empty answer shows "Carries no scopes"', (tester) async {
      final entry = _entry(scopes: const []);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('Carries no scopes'), findsOneWidget);
    });

    testWidgets('a no-response outcome shows its own words, no scope section',
        (tester) async {
      final entry = _entry(outcome: ScopeLogOutcome.noResponse, scopes: null);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('No response from repeater'), findsOneWidget);
      expect(find.text('Carries no scopes'), findsNothing);
    });

    testWidgets('tapping the card calls onTap', (tester) async {
      var tapped = false;
      final entry = _entry();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ScopeLogCard(entry: entry, onTap: () => tapped = true)),
      ));

      await tester.tap(find.byType(ScopeLogCard));
      expect(tapped, isTrue);
    });
  });
}
