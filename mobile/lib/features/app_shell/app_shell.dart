import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calling/call_controller.dart';
import '../../core/calling/call_session.dart';
import '../../core/config/env.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';

/// The app's primary destinations.
///
/// Phase 1 keeps ONE shell for both roles: listener capability is state on the
/// user, not a second navigation tree. That decision is deliberately reversible
/// — nothing here assumes a caller-only app.
enum AppShellTab {
  discovery(
    '/discovery',
    'Discover',
    Icons.explore_outlined,
    Icons.explore_rounded,
  ),
  feed(
    '/feed',
    'Feed',
    Icons.dynamic_feed_outlined,
    Icons.dynamic_feed_rounded,
  ),
  chats(
    '/chats',
    'Chats',
    Icons.chat_bubble_outline_rounded,
    Icons.chat_bubble_rounded,
  ),
  wallet(
    '/wallet',
    'Wallet',
    Icons.account_balance_wallet_outlined,
    Icons.account_balance_wallet_rounded,
  ),
  profile(
    '/profile',
    'Profile',
    Icons.person_outline_rounded,
    Icons.person_rounded,
  );

  const AppShellTab(this.path, this.label, this.icon, this.activeIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// Discovery, Wallet and Chats are real; the rest exist so the tab bar
  /// matches the design and show an explicit development placeholder rather
  /// than invented feature UI.
  bool get isPlaceholder =>
      this != AppShellTab.discovery &&
      this != AppShellTab.wallet &&
      this != AppShellTab.chats;

  String get phase => switch (this) {
    AppShellTab.chats => '',
    AppShellTab.wallet => '',
    AppShellTab.feed => 'a later phase',
    AppShellTab.profile => 'Phase 2',
    AppShellTab.discovery => '',
  };
}

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  int _indexFor(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = AppShellTab.values.indexWhere(
      (tab) => location.startsWith(tab.path),
    );
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = _indexFor(context);

    // Global: an incoming call must interrupt whatever tab is on screen. The
    // controller's socket subscription is already app-lifetime (see
    // CallController), so this only has to react to the phase, not re-listen.
    ref.listen<CallSession>(callControllerProvider, (previous, next) {
      if (previous?.phase != CallPhase.idle) return;
      if (next.phase != CallPhase.incoming) return;
      context.push(Routes.callIncoming);
    });

    return Scaffold(
      extendBody: true,
      body: MocoBackground(ambience: MocoAmbience.rich, child: child),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: MocoColors.backgroundElevated,
          border: Border(top: BorderSide(color: MocoColors.borderSubtle)),
        ),
        child: NavigationBar(
          selectedIndex: index,
          backgroundColor: Colors.transparent,
          indicatorColor: MocoColors.accentPrimary.withValues(alpha: 0.18),
          surfaceTintColor: Colors.transparent,
          height: 66,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => context.go(AppShellTab.values[i].path),
          destinations: [
            for (final tab in AppShellTab.values)
              NavigationDestination(
                icon: Icon(tab.icon, color: MocoColors.textMuted),
                selectedIcon: Icon(
                  tab.activeIcon,
                  color: MocoColors.accentPrimary,
                ),
                label: tab.label,
              ),
          ],
        ),
      ),
    );
  }
}

/// Temporary development placeholder for a tab that has no feature yet.
class PlaceholderTabScreen extends StatelessWidget {
  const PlaceholderTabScreen({super.key, required this.tab});

  final AppShellTab tab;

  @override
  Widget build(BuildContext context) {
    // A production build should never route here, but if it somehow does it
    // must not advertise unreleased phases to a real user.
    if (!Env.showDevPlaceholders) {
      return const MocoEmptyState(
        title: 'Coming soon',
        message: 'This section is not available yet.',
        icon: Icons.hourglass_empty_rounded,
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: MocoSpacing.xxl),
        child: MocoPlaceholderState(feature: tab.label, phase: tab.phase),
      ),
    );
  }
}
