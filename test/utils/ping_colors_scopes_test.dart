import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';
import 'package:mesh_mapper/utils/repeater_marker_style.dart';

/// The log tab's dark card background (`main.dart`'s `darkColorScheme.surface`,
/// which `surfaceContainerHigh` falls back to when unset). Mirrors how
/// `repeater_marker_style_test.dart` checks its accents against a fixed
/// background rather than a live theme.
const _cardBackground = Color(0xFF1E293B);

void main() {
  tearDown(() {
    PingColors.setColorVisionType(ColorVisionType.none);
  });

  group('PingColors.scopes', () {
    for (final cvd in ColorVisionType.values) {
      test('${cvd.name}: clears 3:1 on the card background', () {
        PingColors.setColorVisionType(cvd);
        final ratio =
            RepeaterMarkerStyle.contrastRatio(PingColors.scopes, _cardBackground);
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: 'scopes on ${cvd.name} is only '
                '${ratio.toStringAsFixed(2)}:1');
      });

      test('${cvd.name}: distinct from every other log type accent', () {
        PingColors.setColorVisionType(cvd);
        final others = {
          'txSuccess': PingColors.txSuccess,
          'rx': PingColors.rx,
          'discSuccess': PingColors.discSuccess,
          'traceSuccess': PingColors.traceSuccess,
        };
        final scopesArgb = PingColors.scopes.toARGB32();
        others.forEach((name, color) {
          expect(scopesArgb, isNot(color.toARGB32()),
              reason: 'scopes matches $name under ${cvd.name}');
        });
      });
    }
  });
}
