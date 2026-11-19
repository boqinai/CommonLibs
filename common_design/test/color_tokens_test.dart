import 'dart:ui';

import 'package:common_design/common_design.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves the reviewed light and dark palettes', () {
    expect(CommonColors.resolve(Brightness.light), same(CommonColors.light));
    expect(CommonColors.resolve(Brightness.dark), same(CommonColors.dark));
    expect(CommonColors.light.action.primary, const Color(0xFF3563E9));
    expect(CommonColors.dark.action.primary, const Color(0xFFA6BDFF));
  });

  test(
    'allows application status overrides without changing shared colors',
    () {
      const appSuccess = Color(0xFF0A6B48);
      final customized = CommonColors.light.copyWith(
        status: CommonColors.light.status.copyWith(success: appSuccess),
      );

      expect(customized.status.success, appSuccess);
      expect(customized.action, same(CommonColors.light.action));
      expect(CommonColors.light.status.success, const Color(0xFF16765D));
    },
  );

  test('all required text pairs meet the 4.5 ratio', () {
    for (final colors in [CommonColors.light, CommonColors.dark]) {
      final pairs = <(Color, Color)>[
        (colors.action.onPrimary, colors.action.primary),
        (colors.action.onPrimary, colors.action.hover),
        (colors.action.onPrimary, colors.action.pressed),
        (colors.action.onSoft, colors.action.soft),
        (colors.status.success, colors.status.successSoft),
        (colors.status.warning, colors.status.warningSoft),
        (colors.status.danger, colors.status.dangerSoft),
        (colors.status.onDangerFill, colors.status.dangerFill),
      ];
      for (final pair in pairs) {
        expect(ColorContrast.meetsText(pair.$1, pair.$2), isTrue);
      }

      final surfaceBackgrounds = [
        colors.surface.canvas,
        colors.surface.card,
        colors.surface.subtle,
      ];
      final surfaceForegrounds = [
        colors.text.primary,
        colors.text.secondary,
        colors.action.primary,
        colors.status.success,
        colors.status.warning,
        colors.status.danger,
      ];
      for (final foreground in surfaceForegrounds) {
        for (final background in surfaceBackgrounds) {
          expect(ColorContrast.meetsText(foreground, background), isTrue);
        }
      }
    }
  });

  test('control borders meet 3:1 on shared surfaces', () {
    for (final colors in [CommonColors.light, CommonColors.dark]) {
      for (final surface in [
        colors.surface.canvas,
        colors.surface.card,
        colors.surface.subtle,
      ]) {
        expect(
          ColorContrast.meetsNonText(colors.border.control, surface),
          isTrue,
        );
      }
    }
  });

  test('rejects alpha colors that have not been composited', () {
    expect(
      () => ColorContrast.ratio(
        CommonColors.light.overlay.scrim,
        CommonColors.light.surface.canvas,
      ),
      throwsArgumentError,
    );
  });
}
