import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'moco_colors.dart';
import 'moco_spacing.dart';

/// Material 3 is used as the engine, but every visible surface is overridden so
/// the app reads as Moco rather than as default Material.
class MocoTheme {
  const MocoTheme._();

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
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
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: MocoColors.backgroundPrimary,
      // The ambient background layer supplies the atmosphere, so Material's own
      // surface tinting would only muddy it.
      canvasColor: Colors.transparent,
      splashFactory: InkRipple.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
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
        hintStyle: const TextStyle(color: MocoColors.textMuted),
        labelStyle: const TextStyle(color: MocoColors.textSecondary),
        border: _inputBorder(MocoColors.borderSubtle),
        enabledBorder: _inputBorder(MocoColors.borderSubtle),
        focusedBorder: _inputBorder(MocoColors.accentPrimary, width: 1.5),
        errorBorder: _inputBorder(MocoColors.danger),
        focusedErrorBorder: _inputBorder(MocoColors.danger, width: 1.5),
      ),
      dividerTheme: const DividerThemeData(
        color: MocoColors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
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
        contentTextStyle: const TextStyle(color: MocoColors.textPrimary),
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

  /// The approved reference sets Inter for Latin text and Noto Sans
  /// Devanagari/Telugu for Hindi/Telugu copy. Almost every screen in this app
  /// builds its own `TextStyle(fontSize: ..., color: ...)` inline rather than
  /// reading `Theme.of(context).textTheme` — but none of those inline styles
  /// set `fontFamily`, and `Text` merges its style onto the ambient
  /// `DefaultTextStyle` (which Material derives from this `TextTheme`). So
  /// setting the family once here, via `GoogleFonts.interTextTheme()`, is
  /// enough to change every screen's typeface without editing any of them —
  /// exactly the "central theme" fix this pass calls for.
  ///
  /// `fontFamilyFallback` is what makes Hindi/Telugu strings (chip labels
  /// like "हिंदी"/"తెలుగు", bilingual copy) render in the matching Noto Sans
  /// weight instead of falling back to the platform's own system font for
  /// glyphs Inter doesn't cover — Flutter walks this list per-glyph
  /// automatically; nothing else has to know which script it's rendering.
  static TextTheme _textTheme(TextTheme base) {
    final interTheme = GoogleFonts.interTextTheme(base);
    final fallback = [
      GoogleFonts.notoSansDevanagari().fontFamily!,
      GoogleFonts.notoSansTelugu().fontFamily!,
    ];

    TextStyle? withFallback(TextStyle? style) =>
        style?.copyWith(fontFamilyFallback: fallback);

    return interTheme
        .copyWith(
          displaySmall: withFallback(
            interTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          headlineMedium: withFallback(
            interTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          headlineSmall: withFallback(
            interTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          titleLarge: withFallback(
            interTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          titleMedium: withFallback(
            interTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          bodyLarge: withFallback(interTheme.bodyLarge?.copyWith(height: 1.45)),
          bodyMedium: withFallback(
            interTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          bodySmall: withFallback(interTheme.bodySmall),
          labelLarge: withFallback(
            interTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          labelMedium: withFallback(interTheme.labelMedium),
          labelSmall: withFallback(interTheme.labelSmall),
          titleSmall: withFallback(interTheme.titleSmall),
          displayLarge: withFallback(interTheme.displayLarge),
          displayMedium: withFallback(interTheme.displayMedium),
          headlineLarge: withFallback(interTheme.headlineLarge),
        )
        .apply(
          bodyColor: MocoColors.textPrimary,
          displayColor: MocoColors.textPrimary,
        );
  }

  /// The reference's one deliberate typographic exception: the Discovery
  /// screen's "Discover" wordmark is set in a serif, not Inter. Rather than
  /// pull in a whole new Google Font family for a single word, this uses the
  /// platform's own generic "serif" family name (Noto Serif on Android,
  /// Georgia-equivalent on iOS) — the "closest appropriate serif already
  /// available" rather than a new asset/dependency.
  static const String discoverWordmarkFontFamily = 'serif';
}
