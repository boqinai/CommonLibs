import 'dart:ui';

import 'color_values.dart';

/// Shared application-level semantic colors.
///
/// Domain colors such as finance categories or lottery balls intentionally do
/// not belong here. Applications can override a semantic group with [copyWith]
/// while retaining the common surface, text, and action system.
final class CommonColorTokens {
  const CommonColorTokens({
    required this.brightness,
    required this.brand,
    required this.action,
    required this.surface,
    required this.text,
    required this.border,
    required this.status,
    required this.overlay,
  });

  final Brightness brightness;
  final BrandColors brand;
  final ActionColors action;
  final SurfaceColors surface;
  final TextColors text;
  final BorderColors border;
  final StatusColors status;
  final OverlayColors overlay;

  CommonColorTokens copyWith({
    BrandColors? brand,
    ActionColors? action,
    SurfaceColors? surface,
    TextColors? text,
    BorderColors? border,
    StatusColors? status,
    OverlayColors? overlay,
  }) => CommonColorTokens(
    brightness: brightness,
    brand: brand ?? this.brand,
    action: action ?? this.action,
    surface: surface ?? this.surface,
    text: text ?? this.text,
    border: border ?? this.border,
    status: status ?? this.status,
    overlay: overlay ?? this.overlay,
  );
}

final class BrandColors {
  const BrandColors({
    required this.base,
    required this.onBase,
  });

  /// Brand fill or logo color, not a general-purpose foreground color.
  ///
  /// Use [ActionColors.primary] for brand-colored text and icons on dark
  /// surfaces.
  final Color base;

  /// Text or icon color displayed on [base].
  final Color onBase;
}

final class ActionColors {
  const ActionColors({
    required this.primary,
    required this.onPrimary,
    required this.hover,
    required this.pressed,
    required this.soft,
    required this.onSoft,
  });

  final Color primary;
  final Color onPrimary;
  final Color hover;
  final Color pressed;
  final Color soft;
  final Color onSoft;
}

final class SurfaceColors {
  const SurfaceColors({
    required this.canvas,
    required this.card,
    required this.subtle,
    required this.backgroundSubtle,
    required this.raised,
  });

  final Color canvas;
  final Color card;
  final Color subtle;
  final Color backgroundSubtle;
  final Color raised;
}

final class TextColors {
  const TextColors({
    required this.primary,
    required this.secondary,
    required this.disabled,
  });

  final Color primary;
  final Color secondary;
  final Color disabled;
}

final class BorderColors {
  const BorderColors({required this.subtle, required this.control});

  final Color subtle;
  final Color control;
}

final class StatusColors {
  const StatusColors({
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.dangerFill,
    required this.onDangerFill,
  });

  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;
  final Color dangerFill;
  final Color onDangerFill;

  StatusColors copyWith({
    Color? success,
    Color? successSoft,
    Color? warning,
    Color? warningSoft,
    Color? danger,
    Color? dangerSoft,
    Color? dangerFill,
    Color? onDangerFill,
  }) => StatusColors(
    success: success ?? this.success,
    successSoft: successSoft ?? this.successSoft,
    warning: warning ?? this.warning,
    warningSoft: warningSoft ?? this.warningSoft,
    danger: danger ?? this.danger,
    dangerSoft: dangerSoft ?? this.dangerSoft,
    dangerFill: dangerFill ?? this.dangerFill,
    onDangerFill: onDangerFill ?? this.onDangerFill,
  );
}

final class OverlayColors {
  const OverlayColors({required this.scrim, required this.shadow});

  final Color scrim;
  final Color shadow;
}

/// Reviewed default palette shared by Boqinai applications.
abstract final class CommonColors {
  static const light = CommonColorTokens(
    brightness: Brightness.light,
    brand: BrandColors(
      base: CommonColorValues.lightBrandBase,
      onBase: CommonColorValues.lightBrandOnBase,
    ),
    action: ActionColors(
      primary: CommonColorValues.lightActionPrimary,
      onPrimary: CommonColorValues.lightActionOnPrimary,
      hover: CommonColorValues.lightActionHover,
      pressed: CommonColorValues.lightActionPressed,
      soft: CommonColorValues.lightActionSoft,
      onSoft: CommonColorValues.lightActionOnSoft,
    ),
    surface: SurfaceColors(
      canvas: CommonColorValues.lightSurfaceCanvas,
      card: CommonColorValues.lightSurfaceCard,
      subtle: CommonColorValues.lightSurfaceSubtle,
      backgroundSubtle: CommonColorValues.lightBackgroundSubtle,
      raised: CommonColorValues.lightSurfaceRaised,
    ),
    text: TextColors(
      primary: CommonColorValues.lightTextPrimary,
      secondary: CommonColorValues.lightTextSecondary,
      disabled: CommonColorValues.lightTextDisabled,
    ),
    border: BorderColors(
      subtle: CommonColorValues.lightBorderSubtle,
      control: CommonColorValues.lightBorderControl,
    ),
    status: StatusColors(
      success: CommonColorValues.lightStatusSuccess,
      successSoft: CommonColorValues.lightStatusSuccessSoft,
      warning: CommonColorValues.lightStatusWarning,
      warningSoft: CommonColorValues.lightStatusWarningSoft,
      danger: CommonColorValues.lightStatusDanger,
      dangerSoft: CommonColorValues.lightStatusDangerSoft,
      dangerFill: CommonColorValues.lightStatusDangerFill,
      onDangerFill: CommonColorValues.lightStatusOnDangerFill,
    ),
    overlay: OverlayColors(
      scrim: CommonColorValues.lightOverlayScrim,
      shadow: CommonColorValues.lightOverlayShadow,
    ),
  );

  static const dark = CommonColorTokens(
    brightness: Brightness.dark,
    brand: BrandColors(
      base: CommonColorValues.darkBrandBase,
      onBase: CommonColorValues.darkBrandOnBase,
    ),
    action: ActionColors(
      primary: CommonColorValues.darkActionPrimary,
      onPrimary: CommonColorValues.darkActionOnPrimary,
      hover: CommonColorValues.darkActionHover,
      pressed: CommonColorValues.darkActionPressed,
      soft: CommonColorValues.darkActionSoft,
      onSoft: CommonColorValues.darkActionOnSoft,
    ),
    surface: SurfaceColors(
      canvas: CommonColorValues.darkSurfaceCanvas,
      card: CommonColorValues.darkSurfaceCard,
      subtle: CommonColorValues.darkSurfaceSubtle,
      backgroundSubtle: CommonColorValues.darkBackgroundSubtle,
      raised: CommonColorValues.darkSurfaceRaised,
    ),
    text: TextColors(
      primary: CommonColorValues.darkTextPrimary,
      secondary: CommonColorValues.darkTextSecondary,
      disabled: CommonColorValues.darkTextDisabled,
    ),
    border: BorderColors(
      subtle: CommonColorValues.darkBorderSubtle,
      control: CommonColorValues.darkBorderControl,
    ),
    status: StatusColors(
      success: CommonColorValues.darkStatusSuccess,
      successSoft: CommonColorValues.darkStatusSuccessSoft,
      warning: CommonColorValues.darkStatusWarning,
      warningSoft: CommonColorValues.darkStatusWarningSoft,
      danger: CommonColorValues.darkStatusDanger,
      dangerSoft: CommonColorValues.darkStatusDangerSoft,
      dangerFill: CommonColorValues.darkStatusDangerFill,
      onDangerFill: CommonColorValues.darkStatusOnDangerFill,
    ),
    overlay: OverlayColors(
      scrim: CommonColorValues.darkOverlayScrim,
      shadow: CommonColorValues.darkOverlayShadow,
    ),
  );

  static CommonColorTokens resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}
