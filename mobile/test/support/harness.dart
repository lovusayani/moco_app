import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory token store, so tests never touch the platform keystore.
class FakeSecureStore implements SecureStore {
  FakeSecureStore([this.token]);

  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}

/// Base overrides every screen test needs.
///
/// Screens watch the auth controller, which depends on preferences and the
/// token store, so without these any widget test fails on an unimplemented
/// provider rather than on the behaviour under test.
Future<List<Override>> baseOverrides({FakeSecureStore? store}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await AppPreferences.create();
  return [
    appPreferencesProvider.overrideWithValue(prefs),
    secureStoreProvider.overrideWithValue(store ?? FakeSecureStore()),
  ];
}

/// Wraps a screen that supplies its own Scaffold (onboarding, login, profile
/// setup, listener profile).
Widget wrapWidget(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(theme: MocoTheme.dark, home: child),
  );
}

/// Wraps a screen that lives INSIDE the app shell.
///
/// Discovery is mounted as the ShellRoute's child, so in the real app it always
/// has AppShell's Scaffold — and therefore a Material ancestor — above it. The
/// harness reproduces that rather than testing the screen in a context it never
/// actually renders in.
Widget wrapShellScreen(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: MocoTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

/// Wraps a screen that NAVIGATES with go_router.
///
/// Onboarding calls `context.go` when it finishes, which asserts without a
/// router above it. A minimal two-route router reproduces just enough of the
/// real graph to exercise that.
Widget wrapRoutedScreen(
  Widget child, {
  List<Override> overrides = const [],
  String destination = '/login',
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => child),
      GoRoute(
        path: destination,
        builder: (_, __) => const Scaffold(body: Text('destination')),
      ),
    ],
  );

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(theme: MocoTheme.dark, routerConfig: router),
  );
}
