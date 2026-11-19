import 'dart:ui';

/// Compile-time color constants for consumers that need `const` expressions.
///
/// Prefer [CommonColors] for grouped runtime access. These scalar constants
/// are the same reviewed palette exposed without an object-property lookup.
abstract final class CommonColorValues {
  static const lightBrandBase = Color(0xFF3563E9);
  static const lightBrandOnBase = Color(0xFFFFFFFF);
  static const lightActionPrimary = Color(0xFF3563E9);
  static const lightActionOnPrimary = Color(0xFFFFFFFF);
  static const lightActionHover = Color(0xFF2E57D4);
  static const lightActionPressed = Color(0xFF264BC1);
  static const lightActionSoft = Color(0xFFEAF0FF);
  static const lightActionOnSoft = Color(0xFF264BC1);
  static const lightSurfaceCanvas = Color(0xFFF5F8FF);
  static const lightSurfaceCard = Color(0xFFFFFFFF);
  static const lightSurfaceSubtle = Color(0xFFF8F9FC);
  static const lightBackgroundSubtle = Color(0xFFEEF2F9);
  static const lightSurfaceRaised = Color(0xFFFFFFFF);
  static const lightTextPrimary = Color(0xFF20283D);
  static const lightTextSecondary = Color(0xFF626D83);
  static const lightTextDisabled = Color(0xFF8B95A8);
  static const lightBorderSubtle = Color(0xFFDEE6F3);
  static const lightBorderControl = Color(0xFF758197);
  static const lightStatusSuccess = Color(0xFF16765D);
  static const lightStatusSuccessSoft = Color(0xFFE7F7F1);
  static const lightStatusWarning = Color(0xFF8A5200);
  static const lightStatusWarningSoft = Color(0xFFFFF3DD);
  static const lightStatusDanger = Color(0xFFB34538);
  static const lightStatusDangerSoft = Color(0xFFFCEBE8);
  static const lightStatusDangerFill = Color(0xFFB34538);
  static const lightStatusOnDangerFill = Color(0xFFFFFFFF);
  static const lightOverlayScrim = Color(0x66000000);
  static const lightOverlayShadow = Color(0x1F14234C);

  static const darkBrandBase = Color(0xFF3563E9);
  static const darkBrandOnBase = Color(0xFFFFFFFF);
  static const darkActionPrimary = Color(0xFFA6BDFF);
  static const darkActionOnPrimary = Color(0xFF14234C);
  static const darkActionHover = Color(0xFFB8CBFF);
  static const darkActionPressed = Color(0xFF91ADF5);
  static const darkActionSoft = Color(0xFF263552);
  static const darkActionOnSoft = Color(0xFFC5D5FF);
  static const darkSurfaceCanvas = Color(0xFF11131A);
  static const darkSurfaceCard = Color(0xFF1B1E28);
  static const darkSurfaceSubtle = Color(0xFF232735);
  static const darkBackgroundSubtle = Color(0xFF232735);
  static const darkSurfaceRaised = Color(0xFF2E3446);
  static const darkTextPrimary = Color(0xFFF4F5F7);
  static const darkTextSecondary = Color(0xFFAAB4C6);
  static const darkTextDisabled = Color(0xFF697386);
  static const darkBorderSubtle = Color(0xFF303544);
  static const darkBorderControl = Color(0xFF7C8AA3);
  static const darkStatusSuccess = Color(0xFF3DD6A3);
  static const darkStatusSuccessSoft = Color(0xFF143A30);
  static const darkStatusWarning = Color(0xFFFFD18A);
  static const darkStatusWarningSoft = Color(0xFF3D2D17);
  static const darkStatusDanger = Color(0xFFFFAAA1);
  static const darkStatusDangerSoft = Color(0xFF462722);
  static const darkStatusDangerFill = Color(0xFFFFAAA1);
  static const darkStatusOnDangerFill = Color(0xFF3A1510);
  static const darkOverlayScrim = Color(0x99000000);
  static const darkOverlayShadow = Color(0x52000000);
}
