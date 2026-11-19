import 'dart:io';
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

  test('compile-time values match grouped palettes', () {
    expect(
      CommonColorValues.lightActionPrimary,
      CommonColors.light.action.primary,
    );
    expect(
      CommonColorValues.lightSurfaceCanvas,
      CommonColors.light.surface.canvas,
    );
    expect(
      CommonColorValues.darkActionPrimary,
      CommonColors.dark.action.primary,
    );
    expect(
      CommonColorValues.darkTextPrimary,
      CommonColors.dark.text.primary,
    );
  });

  test('web contract exposes reviewed light and dark roles', () {
    final css = File('web/common-colors.css').readAsStringSync();
    expect(css, contains('--common-action-primary: #3563E9;'));
    expect(css, contains('--common-surface-canvas: #F5F8FF;'));
    expect(css, contains("[data-common-theme='dark']"));
    expect(css, contains('--common-action-primary: #A6BDFF;'));
    expect(css, contains('--common-surface-canvas: #11131A;'));
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

  test('brand fills provide readable content', () {
    for (final colors in [CommonColors.light, CommonColors.dark]) {
      expect(
        ColorContrast.meetsText(colors.brand.onBase, colors.brand.base),
        isTrue,
      );
    }
  });

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
        colors.surface.backgroundSubtle,
        colors.surface.raised,
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

  test('computes known WCAG ratios symmetrically', () {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    const primary = Color(0xFF3563E9);

    expect(ColorContrast.ratio(black, white), closeTo(21, 1e-12));
    expect(ColorContrast.ratio(white, black), closeTo(21, 1e-12));
    expect(ColorContrast.ratio(primary, primary), closeTo(1, 1e-12));
    expect(
      ColorContrast.ratio(primary, white),
      closeTo(5.10607094096039, 1e-12),
    );
  });

  test('enforces the documented contrast thresholds', () {
    const white = Color(0xFFFFFFFF);

    expect(ColorContrast.meetsText(const Color(0xFF767676), white), isTrue);
    expect(ColorContrast.meetsText(const Color(0xFF777777), white), isFalse);
    expect(ColorContrast.meetsNonText(const Color(0xFF949494), white), isTrue);
    expect(ColorContrast.meetsNonText(const Color(0xFF959595), white), isFalse);
  });

  test('control borders meet 3:1 on shared surfaces and soft actions', () {
    for (final colors in [CommonColors.light, CommonColors.dark]) {
      expect(
        ColorContrast.meetsNonText(colors.border.control, colors.action.soft),
        isTrue,
      );
      for (final surface in [
        colors.surface.canvas,
        colors.surface.card,
        colors.surface.subtle,
        colors.surface.backgroundSubtle,
        colors.surface.raised,
      ]) {
        expect(
          ColorContrast.meetsNonText(colors.border.control, surface),
          isTrue,
        );
      }
    }
  });

  test('uses translucent default shadows', () {
    expect(CommonColors.light.overlay.shadow, const Color(0x1F14234C));
    expect(CommonColors.dark.overlay.shadow, const Color(0x52000000));
  });

  test('rejects alpha colors that have not been composited', () {
    const opaque = Color(0xFFFFFFFF);
    final translucent = CommonColors.light.overlay.scrim;

    expect(() => ColorContrast.ratio(translucent, opaque), throwsArgumentError);
    expect(() => ColorContrast.ratio(opaque, translucent), throwsArgumentError);
  });

  test('rejects non-sRGB colors in either position', () {
    const opaque = Color(0xFFFFFFFF);
    const wideGamutColors = [
      Color.from(
        alpha: 1,
        red: 1,
        green: 0,
        blue: 0,
        colorSpace: ColorSpace.displayP3,
      ),
      Color.from(
        alpha: 1,
        red: 1,
        green: 0,
        blue: 0,
        colorSpace: ColorSpace.extendedSRGB,
      ),
    ];

    for (final color in wideGamutColors) {
      expect(() => ColorContrast.ratio(color, opaque), throwsArgumentError);
      expect(() => ColorContrast.ratio(opaque, color), throwsArgumentError);
    }
  });
}
