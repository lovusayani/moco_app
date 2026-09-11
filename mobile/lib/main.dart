import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_state.dart';
import 'core/calling/call_controller.dart';
import 'core/providers.dart';
import 'core/routing/app_router.dart';
import 'core/storage/secure_store.dart';
import 'core/theme/moco_colors.dart';
import 'core/theme/moco_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Let the app's own gradient show through the system bars.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
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
      overrides: [appPreferencesProvider.overrideWithValue(prefs)],
      child: const MocoApp(),
    ),
  );
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
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

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
        theme: MocoTheme.dark,
        home: const _BootstrapScreen(),
      );
    }

    return MaterialApp.router(
      title: 'Moco',
      debugShowCheckedModeBanner: false,
      theme: MocoTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(routerProvider),
    );
  }
}

/// Neutral loading surface shown while the stored session is verified.
///
/// Deliberately not a branded splash — no splash exists in the approved design.
class _BootstrapScreen extends StatelessWidget {
  const _BootstrapScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
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
