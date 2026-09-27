import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/widgets/ping_controls.dart';

/// The "Scopes" badge (owner ruling 15): a small pill at the corner of the
/// running mode's button while the app is asking a discovered repeater for
/// its scopes ([AppStateProvider.isScopeRequestActive]).
///
/// `PingControls`, `CompactPingControls` and `LandscapePingControls` all read
/// a live `AppStateProvider`, whose constructor wires BLE, GPS, Hive and
/// several platform-channel services immediately (`_initialize()`), so none
/// of the three can be built here without a large fake-service harness that
/// does not exist anywhere else in this suite either (no test in the repo
/// constructs `AppStateProvider`). The three button widgets that actually
/// render the badge (`_ActionButton`, `_CompactActionButton`,
/// `_LandscapeIconButton`) are private to `ping_controls.dart`, so this file
/// cannot reach them directly.
///
/// So this suite tests the pieces the fix was pulled into instead:
/// [showsScopesBadge], the one pure per-mode visibility decision every one of
/// the three layouts' six Hybrid/Passive button call sites routes through,
/// and [scopesBadgeSemanticsLabel] (built on [scopesBadgeSemanticsSuffix]),
/// the one pure label composer every one of the three layouts uses to build
/// its Semantics label. [ScopesBadge], the shared pill widget all three
/// layouts render, is pumped directly to confirm its text and color.
/// Exercising these shared, layout-independent functions once covers what
/// every layout does with them; the "layout coverage" group below repeats the
/// same assertions labelled per layout to make that explicit.
void main() {
  group('showsScopesBadge', () {
    test('Passive: shows while running and a scope request is active', () {
      expect(
        showsScopesBadge(AutoMode.passive,
            isModeRunning: true, isScopeRequestActive: true),
        isTrue,
      );
    });

    test('Passive: hidden once the scope request ends', () {
      expect(
        showsScopesBadge(AutoMode.passive,
            isModeRunning: true, isScopeRequestActive: false),
        isFalse,
      );
    });

    test('Passive: hidden when Passive is not the running mode', () {
      expect(
        showsScopesBadge(AutoMode.passive,
            isModeRunning: false, isScopeRequestActive: true),
        isFalse,
      );
    });

    test('Hybrid: shows while running and a scope request is active', () {
      expect(
        showsScopesBadge(AutoMode.hybrid,
            isModeRunning: true, isScopeRequestActive: true),
        isTrue,
      );
    });

    test('Hybrid: hidden once the scope request ends', () {
      expect(
        showsScopesBadge(AutoMode.hybrid,
            isModeRunning: true, isScopeRequestActive: false),
        isFalse,
      );
    });

    test('Hybrid: hidden when Hybrid is not the running mode', () {
      expect(
        showsScopesBadge(AutoMode.hybrid,
            isModeRunning: false, isScopeRequestActive: true),
        isFalse,
      );
    });

    test('Active: never shows, even while "running" with a request active',
        () {
      expect(
        showsScopesBadge(AutoMode.active,
            isModeRunning: true, isScopeRequestActive: true),
        isFalse,
      );
    });

    test('Trace: never shows, even while "running" with a request active',
        () {
      expect(
        showsScopesBadge(AutoMode.targeted,
            isModeRunning: true, isScopeRequestActive: true),
        isFalse,
      );
    });
  });

  group('scopesBadgeSemanticsLabel', () {
    test('leaves the label untouched while inactive', () {
      expect(scopesBadgeSemanticsLabel('Passive Mode', false), 'Passive Mode');
    });

    test('appends the exact phrase while active, keeping the base label',
        () {
      expect(
        scopesBadgeSemanticsLabel('Passive Mode', true),
        'Passive Mode, asking repeaters for scopes',
      );
    });

    test(
        'a countdown baked into the label keeps its text and gains the same '
        'suffix', () {
      // Landscape's tooltip base and compact's expanded label can both carry
      // a live countdown baked into the string; the composer must not touch
      // that text, only append to it.
      expect(
        scopesBadgeSemanticsLabel('Listening 5s', true),
        'Listening 5s, asking repeaters for scopes',
      );
      expect(scopesBadgeSemanticsLabel('Listening 5s', false), 'Listening 5s');
    });

    test('suffix constant matches the phrase the review required', () {
      expect(scopesBadgeSemanticsSuffix, ', asking repeaters for scopes');
    });
  });

  group('ScopesBadge widget', () {
    testWidgets('renders the pill text in the discovery accent color',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ScopesBadge()),
      ));

      expect(find.text('Scopes'), findsOneWidget);

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(ScopesBadge),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFF51D4E9));
    });
  });

  group('layout coverage (portrait, landscape, compact)', () {
    // PingControls, CompactPingControls and LandscapePingControls each read a
    // live AppStateProvider (see the file doc comment for why none can be
    // built here), so this group cannot pump the real portrait/landscape/
    // compact button trees. ping_controls.dart wires all six of their
    // Hybrid/Passive button call sites through showsScopesBadge and every
    // badge's semantics through scopesBadgeSemanticsLabel (verified by source
    // reading in the accompanying fix report), so the groups below stand in
    // for "portrait", "landscape" and "compact" by re-running the shared,
    // layout-independent decision the source wires identically in all three.
    for (final layout in ['portrait', 'landscape', 'compact']) {
      test('$layout: Passive shows only while running and active', () {
        expect(
          showsScopesBadge(AutoMode.passive,
              isModeRunning: true, isScopeRequestActive: true),
          isTrue,
          reason: '$layout Passive button',
        );
        expect(
          showsScopesBadge(AutoMode.passive,
              isModeRunning: true, isScopeRequestActive: false),
          isFalse,
          reason: '$layout Passive button, request ended',
        );
      });

      test('$layout: Hybrid shows only while running and active', () {
        expect(
          showsScopesBadge(AutoMode.hybrid,
              isModeRunning: true, isScopeRequestActive: true),
          isTrue,
          reason: '$layout Hybrid button',
        );
        expect(
          showsScopesBadge(AutoMode.hybrid,
              isModeRunning: true, isScopeRequestActive: false),
          isFalse,
          reason: '$layout Hybrid button, request ended',
        );
      });

      test('$layout: Active and Trace never show it', () {
        for (final mode in [AutoMode.active, AutoMode.targeted]) {
          expect(
            showsScopesBadge(mode,
                isModeRunning: true, isScopeRequestActive: true),
            isFalse,
            reason: '$layout ${mode.name} button',
          );
        }
      });

      test('$layout: label/countdown text is identical with or without it',
          () {
        const baseLabel = 'Next disc 12s';
        expect(scopesBadgeSemanticsLabel(baseLabel, false), baseLabel,
            reason: '$layout, badge hidden');
        expect(
          scopesBadgeSemanticsLabel(baseLabel, true).startsWith(baseLabel),
          isTrue,
          reason: '$layout base label must not be altered by the suffix',
        );
      });

      test('$layout: semantics phrase is present while active', () {
        expect(
          scopesBadgeSemanticsLabel('Passive Mode', true),
          contains(scopesBadgeSemanticsSuffix),
          reason: layout,
        );
      });
    }
  });
}
