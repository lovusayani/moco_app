import 'package:flutter/material.dart';

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

  static TextTheme _textTheme(TextTheme base) {
    return base
        .copyWith(
          displaySmall: base.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          headlineMedium: base.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
          headlineSmall: base.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
          titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
          bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
          labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        )
        .apply(
          bodyColor: MocoColors.textPrimary,
          displayColor: MocoColors.textPrimary,
        );
  }
}
