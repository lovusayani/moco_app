import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'moco_colors.dart';
import 'moco_spacing.dart';

/// The user's selectable typeface — see [AppPreferences.fontChoiceName].
/// Deliberately small: only fonts already shipped with the app are offered,
/// per "do not hardcode fontFamily separately across screens" and "initial
/// supported choices should be limited to fonts already included/approved".
enum MocoFontChoice {
  /// Moco's branded typeface (Inter, via `google_fonts`).
  inter('inter'),

  /// The platform's own default system font.
  system('system');

  const MocoFontChoice(this.storageValue);

  final String storageValue;

  static MocoFontChoice fromStorage(String value) => switch (value) {
    'system' => MocoFontChoice.system,
    _ => MocoFontChoice.inter,
  };
}

/// Material 3 is used as the engine, but every visible surface is overridden so
/// the app reads as Moco rather than as default Material.
///
/// [MocoColors] resolves its tokens against whichever `Brightness` was last
/// passed to [MocoColors.setBrightness] — the app root sets that once per
/// build, before building either [dark] or [light], so the two ThemeData
/// objects and the ambient `MocoColors.*` reads that hundreds of widgets do
/// directly always agree on which appearance is showing.
class MocoTheme {
  const MocoTheme._();

  static ThemeData dark({MocoFontChoice font = MocoFontChoice.inter}) =>
      _build(Brightness.dark, font);

  /// A proper Light appearance, not an inversion of Dark: a warm off-white
  /// ground, dark rose-tinted text, and the same rose/amber brand accents —
  /// see the light ramp in [MocoColors] for the actual token values.
  static ThemeData light({MocoFontChoice font = MocoFontChoice.inter}) =>
      _build(Brightness.light, font);

  static ThemeData _build(Brightness brightness, MocoFontChoice font) {
    final isDark = brightness == Brightness.dark;
    final scheme = isDark
        ? ColorScheme.dark(
            primary: MocoColors.accentPrimary,
            onPrimary: MocoColors.textOnAccent,
            secondary: MocoColors.accentSecondary,
            onSecondary: MocoColors.textOnAccent,
            surface: MocoColors.backgroundElevated,
            onSurface: MocoColors.textPrimary,
            error: MocoColors.danger,
            onError: MocoColors.textOnAccent,
          )
        : ColorScheme.light(
            primary: MocoColors.accentPrimary,
            onPrimary: MocoColors.textOnAccent,
            secondary: MocoColors.accentSecondary,
            onSecondary: MocoColors.textOnAccent,
            surface: MocoColors.backgroundElevated,
            onSurface: MocoColors.textPrimary,
            error: MocoColors.danger,
            onError: MocoColors.textOnAccent,
          );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: MocoColors.backgroundPrimary,
      // The ambient background layer supplies the atmosphere, so Material's own
      // surface tinting would only muddy it.
      canvasColor: Colors.transparent,
      splashFactory: InkRipple.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme, font),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: MocoColors.textPrimary),
        titleTextStyle: TextStyle(
          color: MocoColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MocoColors.surfaceGlass,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: MocoSpacing.lg,
          vertical: MocoSpacing.lg,
        ),
        hintStyle: TextStyle(color: MocoColors.textMuted),
        labelStyle: TextStyle(color: MocoColors.textSecondary),
        border: _inputBorder(MocoColors.borderSubtle),
        enabledBorder: _inputBorder(MocoColors.borderSubtle),
        focusedBorder: _inputBorder(MocoColors.accentPrimary, width: 1.5),
        errorBorder: _inputBorder(MocoColors.danger),
        focusedErrorBorder: _inputBorder(MocoColors.danger, width: 1.5),
      ),
      dividerTheme: DividerThemeData(
        color: MocoColors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: MocoColors.backgroundElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(MocoRadius.xl),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: MocoColors.backgroundAccentStrong,
        contentTextStyle: TextStyle(color: MocoColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MocoRadius.md),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: MocoColors.accentPrimary,
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(MocoRadius.md),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  /// Almost every screen in this app builds its own
  /// `TextStyle(fontSize: ..., color: ...)` inline rather than reading
  /// `Theme.of(context).textTheme` — but none of those inline styles set
  /// `fontFamily`, and `Text` merges its style onto the ambient
  /// `DefaultTextStyle` (which Material derives from this `TextTheme`). So
  /// setting the family once here is enough to change every screen's
  /// typeface without editing any of them.
  ///
  /// `fontFamilyFallback` is what makes Hindi/Telugu strings (chip labels
  /// like "हिंदी"/"తెలుగు", bilingual copy) render in the matching Noto Sans
  /// weight instead of tofu/system fallback for glyphs the chosen font
  /// doesn't cover — Flutter walks this list per-glyph automatically. It is
  /// applied for BOTH font choices, never something the user picks
  /// separately, per "preserve them automatically as script fallbacks".
  static TextTheme _textTheme(TextTheme base, MocoFontChoice font) {
    final fallback = [
      GoogleFonts.notoSansDevanagari().fontFamily!,
      GoogleFonts.notoSansTelugu().fontFamily!,
    ];

    TextStyle? withFallback(TextStyle? style) =>
        style?.copyWith(fontFamilyFallback: fallback);

    // 'system' keeps the platform's own default text theme (San Francisco on
    // iOS, Roboto/whatever the OEM ships on Android) — only the script
    // fallback is added. 'inter' is Moco's branded default.
    final themed = font == MocoFontChoice.system
        ? base
        : GoogleFonts.interTextTheme(base);

    return themed
        .copyWith(
          displaySmall: withFallback(
            themed.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          headlineMedium: withFallback(
            themed.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          headlineSmall: withFallback(
            themed.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          titleLarge: withFallback(
            themed.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          titleMedium: withFallback(
            themed.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          bodyLarge: withFallback(themed.bodyLarge?.copyWith(height: 1.45)),
          bodyMedium: withFallback(themed.bodyMedium?.copyWith(height: 1.45)),
          bodySmall: withFallback(themed.bodySmall),
          labelLarge: withFallback(
            themed.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          labelMedium: withFallback(themed.labelMedium),
          labelSmall: withFallback(themed.labelSmall),
          titleSmall: withFallback(themed.titleSmall),
          displayLarge: withFallback(themed.displayLarge),
          displayMedium: withFallback(themed.displayMedium),
          headlineLarge: withFallback(themed.headlineLarge),
        )
        .apply(bodyColor: MocoColors.textPrimary, displayColor: MocoColors.textPrimary);
  }

  /// The reference's one deliberate typographic exception: the Discovery
  /// screen's "Discover" wordmark is set in a serif, not the body font.
  /// Rather than pull in a whole new Google Font family for a single word,
  /// this uses the platform's own generic "serif" family name (Noto Serif on
  /// Android, Georgia-equivalent on iOS) — the "closest appropriate serif
  /// already available" rather than a new asset/dependency, and it stays
  /// serif regardless of the user's font choice, matching the reference.
  static const String discoverWordmarkFontFamily = 'serif';
}
