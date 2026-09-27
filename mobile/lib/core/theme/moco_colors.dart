import 'package:flutter/material.dart';

/// Moco design tokens.
///
/// Raw hex values live here and nowhere else. Everything in the app reads the
/// semantic names below, so a palette change is a one-file change and there is
/// no way for a stray hex to drift out of the system.
///
/// Every token is a runtime getter, not a `const`, because the app supports a
/// real Light appearance alongside Dark: [setBrightness] flips which ramp the
/// getters resolve against, and every call site simply re-reads
/// `MocoColors.textPrimary` etc. on its next build. This is why every
/// `const TextStyle(color: MocoColors.textPrimary)` in the app had to drop its
/// `const` — a getter call can never be a compile-time constant.
class MocoColors {
  const MocoColors._();

  static Brightness _brightness = Brightness.dark;

  /// Set once per frame by the app root before it rebuilds, from the resolved
  /// `ThemeMode` (System follows `MediaQuery.platformBrightnessOf`). Everything
  /// below reads this, so one call here repaints the whole app.
  static void setBrightness(Brightness value) => _brightness = value;

  static bool get _dark => _brightness == Brightness.dark;

  // ---------------------------------------------------------------- raw ramp — dark
  static const _dBase900 = Color(0xFF120A12);
  static const _dBase800 = Color(0xFF1A0C16);
  static const _dBase700 = Color(0xFF2A101F);
  static const _dBase600 = Color(0xFF341329);

  static const _dSurfaceGlass = Color(0x14FFFFFF);
  static const _dSurfaceGlassStrong = Color(0x24FFFFFF);
  static const _dSurfaceGlassPressed = Color(0x33FFFFFF);
  static const _dBorderSubtle = Color(0x1FFFFFFF);
  static const _dBorderStrong = Color(0x38FFFFFF);

  static const _dText100 = Color(0xFFF5E8E8);
  static const _dText200 = Color(0xFFD8C2CC);
  static const _dText300 = Color(0xFFBFA7B5);

  // --------------------------------------------------------------- raw ramp — light
  // Not an inversion of the dark ramp: a warm off-white ground (never stark
  // white, to stay in the same family as the dark base's warmth), dark
  // rose-tinted text for contrast, and the same rose/amber brand accents
  // carried over unchanged so the app is recognizably Moco in either mode.
  static const _lBase900 = Color(0xFFFBF5F7);
  static const _lBase800 = Color(0xFFF3E8ED);
  static const _lBase700 = Color(0xFFEAD9E1);
  static const _lBase600 = Color(0xFFE0C5D2);

  static const _lSurfaceGlass = Color(0x0A2A101F);
  static const _lSurfaceGlassStrong = Color(0x142A101F);
  static const _lSurfaceGlassPressed = Color(0x1F2A101F);
  static const _lBorderSubtle = Color(0x1F2A101F);
  static const _lBorderStrong = Color(0x382A101F);

  static const _lText100 = Color(0xFF241019);
  static const _lText200 = Color(0xFF4A2E3B);
  static const _lText300 = Color(0xFF6E5560);

  // ---------------------------------------------------- brand ramp (shared)
  // The accent, coin, and status colors are the brand — identical in both
  // appearances, per "preserve brand accent colors appropriately".
  static const _plum = Color(0xFF5A1F3E);
  static const _rose700 = Color(0xFFB93E77);
  static const _rose500 = Color(0xFFE54F9A);
  static const _rose300 = Color(0xFFF07FAE);
  static const _copper = Color(0xFFF29A6E);
  static const _amber = Color(0xFFF6A23C);
  static const _online = Color(0xFF35E98A);
  static const _dangerDark = Color(0xFFF2555A);
  static const _dangerLight = Color(0xFFD0323C);

  // ----------------------------------------------------------- semantic names
  static Color get backgroundPrimary => _dark ? _dBase900 : _lBase900;
  static Color get backgroundElevated => _dark ? _dBase800 : _lBase800;
  static Color get backgroundAccent => _dark ? _dBase700 : _lBase700;
  static Color get backgroundAccentStrong => _dark ? _dBase600 : _lBase600;

  static Color get surfaceGlass => _dark ? _dSurfaceGlass : _lSurfaceGlass;
  static Color get surfaceGlassStrong =>
      _dark ? _dSurfaceGlassStrong : _lSurfaceGlassStrong;
  static Color get surfaceGlassPressed =>
      _dark ? _dSurfaceGlassPressed : _lSurfaceGlassPressed;

  static Color get borderSubtle => _dark ? _dBorderSubtle : _lBorderSubtle;
  static Color get borderStrong => _dark ? _dBorderStrong : _lBorderStrong;

  static const accentPrimary = _rose500;
  static const accentSecondary = _rose700;
  static const accentSoft = _rose300;
  static const accentDeep = _plum;

  static const coinAccent = _amber;
  static const coinAccentSoft = _copper;

  static Color get textPrimary => _dark ? _dText100 : _lText100;
  static Color get textSecondary => _dark ? _dText200 : _lText200;
  static Color get textMuted => _dark ? _dText300 : _lText300;

  static const textOnAccent = Color(0xFFFFFFFF);

  static const success = _online;
  static const online = _online;
  static const warning = _amber;
  static Color get danger => _dark ? _dangerDark : _dangerLight;

  static LinearGradient get backgroundGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: _dark
        ? const [_dBase900, _dBase800, _dBase700]
        : const [_lBase900, _lBase800, _lBase700],
    stops: const [0.0, 0.55, 1.0],
  );

  static const accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [_rose700, _rose500],
  );

  static const coinGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [_copper, _amber],
  );

  static Color get glowRose => _rose500.withValues(alpha: _dark ? 0.28 : 0.16);
  static Color get glowCopper =>
      _copper.withValues(alpha: _dark ? 0.18 : 0.12);
}
