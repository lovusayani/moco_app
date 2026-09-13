import 'dart:ui';

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

  /// All five tabs are real now.
  bool get isPlaceholder => false;

  String get phase => '';
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
      // No bottomNavigationBar slot: the reference's chrome is a floating
      // pill that overlaps the page content rather than a docked bar that
      // reserves its own strip, so it's a Stack layer over the body instead.
      body: MocoBackground(
        ambience: MocoAmbience.rich,
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              left: MocoSpacing.lg,
              right: MocoSpacing.lg,
              bottom: MocoSpacing.lg,
              child: _FloatingNavBar(
                selectedIndex: index,
                onSelect: (i) => context.go(AppShellTab.values[i].path),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating glass-pill tab bar: rounded, inset from both side edges and
/// the bottom, translucent with a blur behind it, and a subtle border —
/// matching the reference's chrome exactly, while keeping every destination,
/// its order, and its action (`context.go` to the same route) unchanged.
///
/// Labels stay visible under each icon. The reference shows icons only, but
/// dropping labels is a usability/accessibility call this pass isn't making
/// unilaterally — matching the chrome first, as directed, and leaving the
/// label question open.
class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({required this.selectedIndex, required this.onSelect});

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.sm),
            decoration: BoxDecoration(
              color: MocoColors.surfaceGlass,
              borderRadius: BorderRadius.circular(MocoRadius.pill),
              border: Border.all(color: MocoColors.borderSubtle),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final tab in AppShellTab.values)
                  _NavItem(
                    tab: tab,
                    selected: AppShellTab.values.indexOf(tab) == selectedIndex,
                    onTap: () => onSelect(AppShellTab.values.indexOf(tab)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final AppShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? MocoColors.accentPrimary : MocoColors.textMuted;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('nav_${tab.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(MocoRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? tab.activeIcon : tab.icon,
                  color: color,
                  size: 22,
                ),
                const SizedBox(height: 2),
                Text(
                  tab.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
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
