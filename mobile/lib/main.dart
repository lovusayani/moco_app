import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'core/auth/auth_state.dart';
import 'core/calling/call_controller.dart';
import 'core/providers.dart';
import 'core/routing/app_router.dart';
import 'core/storage/secure_store.dart';
import 'core/theme/moco_colors.dart';
import 'core/theme/moco_theme.dart';
import 'core/widgets/moco_app_frame.dart';
import 'features/settings/app_settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Web: real paths (/chat/12) instead of hash URLs, and pushed screens are
  // written to the address bar too — so a refresh or a shared link reopens
  // the screen the user was on. Both are no-ops on Android/iOS. Path URLs
  // need the host to serve index.html for unknown paths (see WEB.md).
  usePathUrlStrategy();
  GoRouter.optionURLReflectsImperativeAPIs = true;
  final launchLocation = kIsWeb ? _webLaunchLocation() : null;

  // Let the app's own gradient show through the system bars.
  SystemChrome.setSystemUIOverlayStyle(
     SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: MocoColors.backgroundElevated,
    ),
  );

  // Loaded before runApp so the router's very first redirect already knows
  // whether onboarding was completed — this is what prevents route flicker.
  final prefs = await AppPreferences.create();

  runApp(
    ProviderScope(
      overrides: [
        appPreferencesProvider.overrideWithValue(prefs),
        if (launchLocation != null)
          initialLocationProvider.overrideWithValue(launchLocation),
      ],
      child: const MocoApp(),
    ),
  );
}

/// The in-app location the page was opened at (`/chat/12?x=1`), or null for
/// the site root. Read before runApp — see [initialLocationProvider].
String? _webLaunchLocation() {
  final base = Uri.base;
  if (base.path.isEmpty || base.path == '/') return null;
  return base.hasQuery ? '${base.path}?${base.query}' : base.path;
}

class MocoApp extends ConsumerStatefulWidget {
  const MocoApp({super.key});

  @override
  ConsumerState<MocoApp> createState() => _MocoAppState();
}

class _MocoAppState extends ConsumerState<MocoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Restore the session before the first frame settles.
    Future.microtask(
      () => ref.read(authControllerProvider.notifier).bootstrap(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A call in progress is never torn down just because the app backgrounded
    // — only the server ends a call. On resume, check whether an end event
    // was missed while backgrounded (the socket may have been suspended by
    // the OS) rather than assume the call is still live.
    if (state == AppLifecycleState.resumed) {
      ref.read(callControllerProvider.notifier).reconcile();
    }
  }

  @override
  void didChangePlatformBrightness() {
    // Only matters when following System — but rebuilding unconditionally is
    // harmless, and this is the one hook the platform gives us for "the OS
    // theme changed while the app was already open".
    setState(() {});
  }

  /// Resolves the user's [ThemeMode] preference to a concrete [Brightness],
  /// then stamps it onto [MocoColors] before anything below reads it. This is
  /// the one line that makes System mode actually follow the OS: every other
  /// screen just reads `MocoColors.*` directly, never `Theme.of(context)`.
  Brightness _resolveBrightness(ThemeMode mode) => switch (mode) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final fontChoice = ref.watch(fontChoiceProvider);

    MocoColors.setBrightness(_resolveBrightness(themeMode));

    // The socket follows the session: connected while signed in, torn down on
    // sign-out. Kept here so exactly one instance exists for the whole app.
    ref.listen<AuthState>(authControllerProvider, (
      AuthState? previous,
      AuthState next,
    ) async {
      final socket = ref.read(socketServiceProvider);
      if (next.isSignedIn && !socket.isActive) {
        final token = await ref.read(secureStoreProvider).readToken();
        if (token != null && token.isNotEmpty) socket.connect(token);
      } else if (!next.isSignedIn && socket.isActive) {
        socket.disconnect();
      }
    });

    // Hold on a neutral bootstrap surface until the session is resolved, rather
    // than routing through login on the way to discovery.
    if (auth.status == AuthStatus.initializing) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MocoTheme.light(font: fontChoice),
        darkTheme: MocoTheme.dark(font: fontChoice),
        themeMode: themeMode,
        scrollBehavior: _scrollBehavior,
        builder: _frame,
        home: const _BootstrapScreen(),
      );
    }

    return MaterialApp.router(
      title: 'Moco',
      debugShowCheckedModeBanner: false,
      theme: MocoTheme.light(font: fontChoice),
      darkTheme: MocoTheme.dark(font: fontChoice),
      themeMode: themeMode,
      scrollBehavior: _scrollBehavior,
      builder: _frame,
      routerConfig: ref.watch(routerProvider),
    );
  }
}

/// Web only: mouse/trackpad drag scrolling for desktop browsers. Native keeps
/// Flutter's default behaviour.
const ScrollBehavior? _scrollBehavior = kIsWeb ? MocoWebScrollBehavior() : null;

/// Web only: the centred phone-width column on wide windows (MocoAppFrame).
Widget _frame(BuildContext context, Widget? child) {
  final content = child ?? const SizedBox.shrink();
  return kIsWeb ? MocoAppFrame(child: content) : content;
}

/// Neutral loading surface shown while the stored session is verified.
///
/// Deliberately not a branded splash — no splash exists in the approved design.
class _BootstrapScreen extends StatelessWidget {
  const _BootstrapScreen();

  @override
  Widget build(BuildContext context) {
    return  Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      body: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }
}
