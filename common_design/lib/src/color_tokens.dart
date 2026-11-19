import 'dart:ui';

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
  const BrandColors({required this.base});

  final Color base;
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
    brand: BrandColors(base: Color(0xFF3563E9)),
    action: ActionColors(
      primary: Color(0xFF3563E9),
      onPrimary: Color(0xFFFFFFFF),
      hover: Color(0xFF2E57D4),
      pressed: Color(0xFF264BC1),
      soft: Color(0xFFEAF0FF),
      onSoft: Color(0xFF264BC1),
    ),
    surface: SurfaceColors(
      canvas: Color(0xFFF5F8FF),
      card: Color(0xFFFFFFFF),
      subtle: Color(0xFFF8F9FC),
      backgroundSubtle: Color(0xFFEEF2F9),
      raised: Color(0xFFFFFFFF),
    ),
    text: TextColors(
      primary: Color(0xFF20283D),
      secondary: Color(0xFF626D83),
      disabled: Color(0xFF8B95A8),
    ),
    border: BorderColors(subtle: Color(0xFFDEE6F3), control: Color(0xFF758197)),
    status: StatusColors(
      success: Color(0xFF16765D),
      successSoft: Color(0xFFE7F7F1),
      warning: Color(0xFF8A5200),
      warningSoft: Color(0xFFFFF3DD),
      danger: Color(0xFFB34538),
      dangerSoft: Color(0xFFFCEBE8),
      dangerFill: Color(0xFFB34538),
      onDangerFill: Color(0xFFFFFFFF),
    ),
    overlay: OverlayColors(scrim: Color(0x66000000), shadow: Color(0xFF000000)),
  );

  static const dark = CommonColorTokens(
    brightness: Brightness.dark,
    brand: BrandColors(base: Color(0xFF3563E9)),
    action: ActionColors(
      primary: Color(0xFFA6BDFF),
      onPrimary: Color(0xFF14234C),
      hover: Color(0xFFB8CBFF),
      pressed: Color(0xFF91ADF5),
      soft: Color(0xFF263552),
      onSoft: Color(0xFFC5D5FF),
    ),
    surface: SurfaceColors(
      canvas: Color(0xFF11131A),
      card: Color(0xFF1B1E28),
      subtle: Color(0xFF232735),
      backgroundSubtle: Color(0xFF232735),
      raised: Color(0xFF2E3446),
    ),
    text: TextColors(
      primary: Color(0xFFF4F5F7),
      secondary: Color(0xFFAAB4C6),
      disabled: Color(0xFF697386),
    ),
    border: BorderColors(subtle: Color(0xFF303544), control: Color(0xFF7C8AA3)),
    status: StatusColors(
      success: Color(0xFF3DD6A3),
      successSoft: Color(0xFF143A30),
      warning: Color(0xFFFFD18A),
      warningSoft: Color(0xFF3D2D17),
      danger: Color(0xFFFFAAA1),
      dangerSoft: Color(0xFF462722),
      dangerFill: Color(0xFFFFAAA1),
      onDangerFill: Color(0xFF3A1510),
    ),
    overlay: OverlayColors(scrim: Color(0x99000000), shadow: Color(0xFF000000)),
  );

  static CommonColorTokens resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}
