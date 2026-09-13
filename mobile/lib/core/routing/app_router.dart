import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/app_shell/app_shell.dart';
import '../../features/auth/login_screen.dart';
import '../../features/calling/active_audio_call_screen.dart';
import '../../features/calling/active_video_call_screen.dart';
import '../../features/calling/call_ended_summary_screen.dart';
import '../../features/calling/incoming_call_screen.dart';
import '../../features/calling/outgoing_call_screen.dart';
import '../../features/chat_thread/chat_thread_screen.dart';
import '../../features/chats/chats_screen.dart';
import '../../features/discovery/discovery_screen.dart';
import '../../features/feed/feed_screen.dart';
import '../../features/feed/post_composer_screen.dart';
import '../../features/profile/account_settings_screen.dart';
import '../../features/profile/edit_profile_screen.dart';
import '../../features/profile/ledger_controller.dart';
import '../../features/profile/ledger_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/listener_profile/listener_profile_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/profile_setup/profile_setup_screen.dart';
import '../../features/wallet/wallet_screen.dart';
import '../../shared/models/chat.dart';
import '../auth/auth_state.dart';
import '../providers.dart';

/// Route paths, named once so no screen builds a path from a string literal.
class Routes {
  const Routes._();

  static const onboarding = '/onboarding';
  static const login = '/login';
  static const profileSetup = '/profile-setup';
  static const app = '/app';
  static const discovery = '/discovery';
  static const wallet = '/wallet';
  static const chats = '/chats';
  static const feed = '/feed';
  static const profile = '/profile';
  static const editProfile = '/profile/edit';
  static const accountSettings = '/profile/settings';
  static const coinLedger = '/profile/ledger/coins';
  static const earningsLedger = '/profile/ledger/earnings';
  static const notifications = '/notifications';

  /// Deep-link safe: the listener id is a path segment, so
  /// `moco://listener/42` maps cleanly once deep links are enabled.
  static const listener = '/listener/:id';
  static String listenerPath(int id) => '/listener/$id';

  /// The counterparty's id, same deep-link-safe shape as [listener]. The
  /// Chats row passes the [Conversation] it already has via `extra` so the
  /// thread header doesn't wait on a network round trip to show a name — but
  /// the id in the path is what the screen and controller actually key off.
  static const chatThread = '/chat/:userId';
  static String chatThreadPath(int userId) => '/chat/$userId';

  /// The post composer is full-screen over the shell, like a call screen —
  /// publishing should not be interrupted by a stray tab tap.
  static const postCompose = '/feed/compose';

  /// Call screens read the live [CallSession] from `callControllerProvider`
  /// rather than route parameters — there is exactly one call in progress at
  /// a time, so nothing here needs to be threaded through the URL.
  static const callOutgoing = '/call/outgoing';
  static const callIncoming = '/call/incoming';
  static const callActiveAudio = '/call/active/audio';
  static const callActiveVideo = '/call/active/video';
  static const callSummary = '/call/summary';
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authActionsProvider);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: Routes.app,
    // The controller is a Listenable, so every auth change re-evaluates
    // redirects. This is what keeps routing and session state in lockstep.
    refreshListenable: auth,
    redirect: (context, state) => _redirect(auth.value, state),
    routes: [
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.profileSetup,
        builder: (context, state) => const ProfileSetupScreen(),
      ),
      GoRoute(
        path: Routes.listener,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return ListenerProfileScreen(listenerId: id);
        },
      ),
      // Call screens are full-screen and outside the tab shell, like a phone
      // call overlaying whatever app was open — none of them are reachable by
      // a back-swipe (each disables system pop; the call controller owns
      // leaving a call, not the navigator).
      GoRoute(
        path: Routes.callOutgoing,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const OutgoingCallScreen(),
      ),
      GoRoute(
        path: Routes.callIncoming,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const IncomingCallScreen(),
      ),
      GoRoute(
        path: Routes.callActiveAudio,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const ActiveAudioCallScreen(),
      ),
      GoRoute(
        path: Routes.callActiveVideo,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const ActiveVideoCallScreen(),
      ),
      GoRoute(
        path: Routes.callSummary,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const CallEndedSummaryScreen(),
      ),
      // Full-screen over the shell, like Listener Profile — Chats stays
      // mounted underneath so it keeps receiving chat:message live.
      GoRoute(
        path: Routes.chatThread,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['userId'] ?? '');
          final conversation = state.extra is Conversation
              ? state.extra as Conversation
              : null;
          return ChatThreadScreen(
            counterpartyId: id ?? conversation?.counterpartyId ?? 0,
            counterpartyName: conversation?.displayName,
            counterpartyAvatarUrl: conversation?.counterpartyAvatarUrl,
          );
        },
      ),
      GoRoute(
        path: Routes.postCompose,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const PostComposerScreen(),
      ),
      GoRoute(
        path: Routes.notifications,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.editProfile,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => EditProfileScreen(
          startWithListenerApplication: state.extra == true,
        ),
      ),
      GoRoute(
        path: Routes.accountSettings,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const AccountSettingsScreen(),
      ),
      GoRoute(
        path: Routes.coinLedger,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => LedgerScreen(
          title: 'Coin ledger',
          provider: walletLedgerControllerProvider,
          currencyPrefix: '',
        ),
      ),
      GoRoute(
        path: Routes.earningsLedger,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => LedgerScreen(
          title: 'Earnings history',
          provider: earningsLedgerControllerProvider,
          currencyPrefix: '₹',
        ),
      ),
      // One shell for both roles. Listener capability is modelled as user state
      // rather than a second navigation tree (Phase 1 decision).
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: Routes.app, redirect: (_, __) => Routes.discovery),
          GoRoute(
            path: Routes.discovery,
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: DiscoveryScreen()),
          ),
          GoRoute(
            path: Routes.wallet,
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: WalletScreen()),
          ),
          GoRoute(
            path: Routes.chats,
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: ChatsScreen()),
          ),
          GoRoute(
            path: Routes.feed,
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: FeedScreen()),
          ),
          GoRoute(
            path: Routes.profile,
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: ProfileScreen()),
          ),
          for (final tab in AppShellTab.values.where((t) => t.isPlaceholder))
            GoRoute(
              path: tab.path,
              pageBuilder: (context, state) =>
                  NoTransitionPage(child: PlaceholderTabScreen(tab: tab)),
            ),
        ],
      ),
    ],
    errorBuilder: (context, state) => const _RouteNotFound(),
  );
});

/// The single startup decision, evaluated on every navigation.
///
/// Order matters and mirrors the launch flow: onboarding, then authentication,
/// then profile completeness. Returning null while initializing is what avoids
/// redirect flicker — the app holds on the bootstrap screen instead of
/// bouncing through login on its way to discovery.
String? _redirect(AuthState auth, GoRouterState state) {
  if (auth.isInitializing) return null;

  final location = state.matchedLocation;
  final atOnboarding = location == Routes.onboarding;
  final atLogin = location == Routes.login;
  final atProfileSetup = location == Routes.profileSetup;

  if (!auth.onboardingComplete) {
    return atOnboarding ? null : Routes.onboarding;
  }

  switch (auth.status) {
    case AuthStatus.initializing:
      return null;
    case AuthStatus.unauthenticated:
      return atLogin ? null : Routes.login;
    case AuthStatus.awaitingProfile:
      return atProfileSetup ? null : Routes.profileSetup;
    case AuthStatus.authenticated:
      // Bounce away from the pre-auth screens once signed in and complete.
      if (atOnboarding || atLogin || atProfileSetup) return Routes.discovery;
      return null;
  }
}

class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => context.go(Routes.discovery),
          child: const Text('Page not found — back to Discovery'),
        ),
      ),
    );
  }
}
