import 'dart:ui';

/// Utilities for validating opaque sRGB foreground/background combinations.
abstract final class ColorContrast {
  /// WCAG contrast ratio, ranging from 1 to 21.
  ///
  /// Both colors must be opaque and use the sRGB color space. Alpha colors
  /// need to be composited onto their rendered background before they can be
  /// measured accurately.
  static double ratio(Color foreground, Color background) {
    if (foreground.a != 1 || background.a != 1) {
      throw ArgumentError('Contrast colors must be opaque.');
    }
    if (foreground.colorSpace != ColorSpace.sRGB ||
        background.colorSpace != ColorSpace.sRGB) {
      throw ArgumentError('Contrast colors must use the sRGB color space.');
    }
    final foregroundLuminance = foreground.computeLuminance();
    final backgroundLuminance = background.computeLuminance();
    final lighter = foregroundLuminance > backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    final darker = foregroundLuminance > backgroundLuminance
        ? backgroundLuminance
        : foregroundLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Whether readable text meets the shared 4.5:1 project threshold.
  static bool meetsText(Color foreground, Color background) =>
      ratio(foreground, background) >= 4.5;

  /// Whether a meaningful control boundary or icon meets 3:1.
  static bool meetsNonText(Color foreground, Color background) =>
      ratio(foreground, background) >= 3;
}
