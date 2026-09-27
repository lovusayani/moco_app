import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/storage/secure_store.dart';
import '../../core/theme/moco_theme.dart';

/// Display appearance. Persisted locally only — this is a client preference,
/// not something the backend has any concept of.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._prefs) : super(_fromStorage(_prefs.themeModeName));

  final AppPreferences _prefs;

  static ThemeMode _fromStorage(String value) => switch (value) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  static String _toStorage(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.system => 'system',
    ThemeMode.dark => 'dark',
  };

  Future<void> setMode(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;
    await _prefs.setThemeModeName(_toStorage(mode));
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(ref.watch(appPreferencesProvider)),
);

/// Which typeface the app renders in — see [MocoFontChoice].
class FontChoiceController extends StateNotifier<MocoFontChoice> {
  FontChoiceController(this._prefs)
    : super(MocoFontChoice.fromStorage(_prefs.fontChoiceName));

  final AppPreferences _prefs;

  Future<void> setChoice(MocoFontChoice choice) async {
    if (choice == state) return;
    state = choice;
    await _prefs.setFontChoiceName(choice.storageValue);
  }
}

final fontChoiceProvider =
    StateNotifierProvider<FontChoiceController, MocoFontChoice>(
      (ref) => FontChoiceController(ref.watch(appPreferencesProvider)),
    );

/// How many columns Discovery's grid renders — 1 (large cards), 2 (medium),
/// or 3 (compact, matching the approved UI reference). Purely a layout
/// preference: the backend query Discovery makes never changes because of it.
class DiscoveryColumnsController extends StateNotifier<int> {
  DiscoveryColumnsController(this._prefs) : super(_clamp(_prefs.discoveryColumns));

  final AppPreferences _prefs;

  static int _clamp(int value) => value < 1 ? 1 : (value > 3 ? 3 : value);

  Future<void> setColumns(int columns) async {
    final clamped = _clamp(columns);
    if (clamped == state) return;
    state = clamped;
    await _prefs.setDiscoveryColumns(clamped);
  }
}

final discoveryColumnsProvider =
    StateNotifierProvider<DiscoveryColumnsController, int>(
      (ref) => DiscoveryColumnsController(ref.watch(appPreferencesProvider)),
    );
