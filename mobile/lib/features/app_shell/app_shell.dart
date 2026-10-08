import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calling/call_controller.dart';
import '../../core/calling/call_session.dart';
import '../../core/config/env.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';
import '../discovery/discovery_controller.dart';
import 'web_top_bar.dart';

/// The app's primary destinations.
///
/// Phase 1 keeps ONE shell for both roles: listener capability is state on the
/// user, not a second navigation tree. That decision is deliberately reversible
/// — nothing here assumes a caller-only app.
enum AppShellTab {
  // Order is the approved final nav order: Feed is the center tab, Chat sits
  // directly beside Profile. This enum's declaration order IS the bottom
  // nav's render order (`_FloatingNavBar` iterates `AppShellTab.values`), so
  // reordering here is the one edit needed — no other index mapping exists.
  discovery(
    '/discovery',
    'Discover',
    Icons.explore_outlined,
    Icons.explore_rounded,
  ),
  wallet(
    '/wallet',
    'Wallet',
    Icons.account_balance_wallet_outlined,
    Icons.account_balance_wallet_rounded,
  ),
  feed(
    '/feed',
    'Feed',
    Icons.dynamic_feed_outlined,
    Icons.dynamic_feed_rounded,
  ),
  chats(
    '/chats',
    'Chat',
    Icons.chat_bubble_outline_rounded,
    Icons.chat_bubble_rounded,
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

/// The web app's bottom nav. It differs from [AppShellTab] (Android) in two
/// places: Wallet is not a tab (it stays reachable from Profile → Wallet &
/// top-up, and from every "add coins" prompt), and Discovery's header search
/// button becomes the Search tab. Live and Search both show the same
/// Discovery screen and reuse its search state — Search only opens and
/// focuses the existing search field.
enum WebShellTab {
  live('Live', Icons.home_outlined, Icons.home_rounded),
  search('Search', Icons.search_rounded, Icons.search_rounded),
  feed('Feed', Icons.video_call_outlined, Icons.video_call_rounded),
  chats('Chat', Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
  profile('Profile', Icons.person_outline_rounded, Icons.person_rounded);

  const WebShellTab(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;

  String get path => switch (this) {
    live || search => Routes.discovery,
    feed => Routes.feed,
    chats => Routes.chats,
    profile => Routes.profile,
  };

  /// The tab to highlight at [location], or null where no tab owns the page
  /// (e.g. /wallet, reached from Profile).
  static WebShellTab? forLocation(String location, {required bool searchOpen}) {
    if (location.startsWith(Routes.discovery)) {
      return searchOpen ? search : live;
    }
    if (location.startsWith(Routes.feed)) return feed;
    if (location.startsWith(Routes.chats)) return chats;
    if (location.startsWith(Routes.profile)) return profile;
    return null;
  }
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

  Widget _webNav(BuildContext context, WidgetRef ref) {
    final selected = WebShellTab.forLocation(
      GoRouterState.of(context).matchedLocation,
      searchOpen: ref.watch(discoveryWebSearchOpenProvider),
    );
    return _FloatingNavBar(
      compact: true,
      items: [
        for (final tab in WebShellTab.values)
          _NavItem(
            key: Key('nav_${tab.name}'),
            showLabel: false,
            label: tab.label,
            icon: tab.icon,
            activeIcon: tab.activeIcon,
            selected: tab == selected,
            onTap: () {
              if (tab == WebShellTab.live) {
                ref.read(discoveryWebSearchOpenProvider.notifier).state = false;
              } else if (tab == WebShellTab.search) {
                ref.read(discoveryWebSearchOpenProvider.notifier).state = true;
                ref.read(discoveryWebSearchFocusProvider.notifier).state++;
              }
              context.go(tab.path);
            },
          ),
      ],
    );
  }

  Widget _nativeNav(BuildContext context) {
    final index = _indexFor(context);
    return _FloatingNavBar(
      items: [
        for (final tab in AppShellTab.values)
          _NavItem(
            key: Key('nav_${tab.name}'),
            label: tab.label,
            icon: tab.icon,
            activeIcon: tab.activeIcon,
            selected: AppShellTab.values.indexOf(tab) == index,
            onTap: () => context.go(tab.path),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWeb = ref.watch(platformCapabilitiesProvider).isWeb;

    // Global: an incoming call must interrupt whatever tab is on screen. The
    // controller's socket subscription is already app-lifetime (see
    // CallController), so this only has to react to the phase, not re-listen.
    ref.listen<CallSession>(callControllerProvider, (previous, next) {
      if (previous?.phase != CallPhase.idle) return;
      if (next.phase != CallPhase.incoming) return;
      // Where calls cannot be answered (web), say so instead of opening an
      // Accept button that could never connect media. The session is left
      // alone: the server still ends or times out the call as usual, and a
      // signed-in Android device can still answer it.
      if (!ref.read(platformCapabilitiesProvider).supportsCalling) {
        final from = next.counterpartyName;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('incoming_call_unavailable_snackbar'),
            content: Text(
              '${from == null || from.isEmpty ? 'Incoming call' : 'Incoming call from $from'}'
              ' — answer it in the Moco Android app.',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }
      context.push(Routes.callIncoming);
    });

    final location = GoRouterState.of(context).matchedLocation;

    return Scaffold(
      drawer: isWeb ? const WebSideDrawer() : null,
      // No bottomNavigationBar slot: the reference's chrome is a floating
      // pill that overlaps the page content rather than a docked bar that
      // reserves its own strip, so it's a Stack layer over the body instead.
      body: MocoBackground(
        ambience: MocoAmbience.rich,
        child: Stack(
          children: [
            Positioned.fill(child: child),
            // Web only, on Discover: menu, Call/Live/Video capsule, wallet, bell.
            if (isWeb && WebTopItem.showsOn(location))
              Positioned(
                left: MocoSpacing.screenPadding,
                right: MocoSpacing.screenPadding,
                top: MediaQuery.paddingOf(context).top + MocoSpacing.md,
                child: _AutoHide(
                  // Only Discover hides it while scrolling.
                  visible:
                      !location.startsWith(Routes.discovery) ||
                      ref.watch(discoveryWebTopBarVisibleProvider),
                  child: const WebTopBar(),
                ),
              ),
            if (isWeb)
              // Web: a compact, icon-only pill, centred and width-capped.
              Positioned(
                left: MocoSpacing.lg,
                right: MocoSpacing.lg,
                bottom: MocoSpacing.md,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: _webNav(context, ref),
                  ),
                ),
              )
            else
              Positioned(
                left: MocoSpacing.lg,
                right: MocoSpacing.lg,
                bottom: MocoSpacing.lg,
                child: _nativeNav(context),
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
  const _FloatingNavBar({required this.items, this.compact = false});

  final List<_NavItem> items;

  /// Web: icon-only items in a slimmer bar.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: compact ? 52 : 64,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? MocoSpacing.xs : MocoSpacing.sm,
            ),
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
              children: items,
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onTap,
    this.showLabel = true,
  });

  final String label;
  final bool showLabel;
  final IconData icon;
  final IconData activeIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? MocoColors.accentPrimary : MocoColors.textMuted;

    if (!showLabel) {
      // Icon only; the label stays as the tooltip and screen-reader name.
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          excludeSemantics: true,
          child: Tooltip(
            message: label,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(MocoRadius.pill),
                child: Center(
                  child: AnimatedContainer(
                    duration: MocoDuration.sheet,
                    curve: Curves.easeOutCubic,
                    width: 44,
                    height: 36,
                    decoration: BoxDecoration(
                      color: selected
                          ? MocoColors.accentPrimary.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(MocoRadius.pill),
                    ),
                    child: Icon(
                      selected ? activeIcon : icon,
                      color: color,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MocoRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(selected ? activeIcon : icon, color: color, size: 22),
                const SizedBox(height: 2),
                Text(
                  label,
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

/// Slides [child] up and fades it out when not [visible] — slowly, so the
/// top bar drifts away and back rather than snapping.
class _AutoHide extends StatelessWidget {
  const _AutoHide({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  static const _duration = Duration(milliseconds: 650);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: _duration,
        curve: Curves.easeInOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -1.6),
        child: AnimatedOpacity(
          duration: _duration,
          curve: Curves.easeInOut,
          opacity: visible ? 1 : 0,
          child: child,
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
