import 'package:flutter/material.dart';

/// Moco design tokens.
///
/// Raw hex values live here and nowhere else. Everything in the app reads the
/// semantic names below, so a palette change is a one-file change and there is
/// no way for a stray hex to drift out of the system.
class MocoColors {
  const MocoColors._();

  // ---------------------------------------------------------------- raw ramp
  static const _base900 = Color(0xFF120A12);
  static const _base800 = Color(0xFF1A0C16);
  static const _base700 = Color(0xFF2A101F);
  static const _base600 = Color(0xFF341329);

  static const _plum = Color(0xFF5A1F3E);

  static const _rose700 = Color(0xFFB93E77);
  static const _rose500 = Color(0xFFE54F9A);
  static const _rose300 = Color(0xFFF07FAE);

  static const _copper = Color(0xFFF29A6E);
  static const _amber = Color(0xFFF6A23C);

  static const _text100 = Color(0xFFF5E8E8);
  static const _text200 = Color(0xFFD8C2CC);
  static const _text300 = Color(0xFFBFA7B5);

  static const _online = Color(0xFF35E98A);

  // ----------------------------------------------------------- semantic names
  /// Deepest ground. The app's default scaffold colour.
  static const backgroundPrimary = _base900;

  /// One step up from the ground — sheets and raised sections.
  static const backgroundElevated = _base800;

  /// Used for the ambient gradient stops, not for flat fills.
  static const backgroundAccent = _base700;
  static const backgroundAccentStrong = _base600;

  /// Translucent card fill. Deliberately low alpha: the ambient background is
  /// meant to read through the glass.
  static const surfaceGlass = Color(0x14FFFFFF);

  /// For surfaces that must stay legible over the busiest backgrounds.
  static const surfaceGlassStrong = Color(0x24FFFFFF);

  /// Pressed/hover fill for interactive glass.
  static const surfaceGlassPressed = Color(0x33FFFFFF);

  static const borderSubtle = Color(0x1FFFFFFF);
  static const borderStrong = Color(0x38FFFFFF);

  static const accentPrimary = _rose500;
  static const accentSecondary = _rose700;
  static const accentSoft = _rose300;
  static const accentDeep = _plum;

  /// Coins and money. Copper reads as currency without competing with rose.
  static const coinAccent = _amber;
  static const coinAccentSoft = _copper;

  static const textPrimary = _text100;
  static const textSecondary = _text200;
  static const textMuted = _text300;

  /// Text drawn on top of a filled accent button.
  static const textOnAccent = Color(0xFFFFFFFF);

  static const success = _online;
  static const online = _online;
  static const warning = _amber;
  static const danger = Color(0xFFF2555A);

  /// Gradient for the app's ambient ground.
  static const backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_base900, _base800, _base700],
    stops: [0.0, 0.55, 1.0],
  );

  /// Primary action fill.
  static const accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [_rose700, _rose500],
  );

  /// Reserved for coin and earning surfaces.
  static const coinGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [_copper, _amber],
  );

  /// Rose glow used behind hero elements.
  static Color get glowRose => _rose500.withValues(alpha: 0.28);

  /// Copper highlight, used sparingly as a secondary light source.
  static Color get glowCopper => _copper.withValues(alpha: 0.18);
}
