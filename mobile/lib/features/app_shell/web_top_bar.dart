import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../discovery/discovery_controller.dart';
import '../notifications/notifications_controller.dart';

/// The web top bar's centre capsule. Call and Video are Discovery's existing
/// Audio/Video modes; Feed is the existing Feed; Live is an empty placeholder.
enum WebTopItem {
  call('Call', Icons.call_rounded),
  live('Live', Icons.sensors_rounded),
  feed('Feed', Icons.slow_motion_video_rounded),
  video('Video', Icons.videocam_rounded);

  const WebTopItem(this.label, this.icon);

  final String label;
  final IconData icon;

  /// The item to highlight at [location], or null where none owns the page.
  static WebTopItem? forLocation(String location, CallMode mode) {
    if (location.startsWith(Routes.live)) return live;
    if (location.startsWith(Routes.feed)) return feed;
    if (location.startsWith(Routes.discovery)) {
      return mode == CallMode.video ? video : call;
    }
    return null;
  }

  /// Pages that show the top bar on web: the capsule's own destinations.
  static bool showsOn(String location) =>
      location.startsWith(Routes.discovery) ||
      location.startsWith(Routes.live) ||
      (location.startsWith(Routes.feed) &&
          !location.startsWith(Routes.postCompose));
}

/// Web only: [ menu ]  [ call | live | feed | video ]  [ wallet ] [ bell ].
class WebTopBar extends ConsumerWidget {
  const WebTopBar({super.key});

  static const double height = 44;

  void _select(BuildContext context, WidgetRef ref, WebTopItem item) {
    switch (item) {
      case WebTopItem.call:
      case WebTopItem.video:
        ref
            .read(discoveryControllerProvider.notifier)
            .setMode(
              item == WebTopItem.video ? CallMode.video : CallMode.audio,
            );
        context.go(Routes.discovery);
      case WebTopItem.live:
        context.go(Routes.live);
      case WebTopItem.feed:
        context.go(Routes.feed);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final mode = ref.watch(discoveryControllerProvider.select((s) => s.mode));
    final selected = WebTopItem.forLocation(location, mode);
    final balance = ref.watch(
      authControllerProvider.select((s) => s.user?.coinBalance),
    );

    return SizedBox(
      key: const Key('web_top_bar'),
      height: height,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: MocoIconButton(
                key: const Key('topbar_menu'),
                icon: Icons.menu_rounded,
                size: 40,
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          ),
          _Capsule(
            selected: selected,
            onSelect: (item) => _select(context, ref, item),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              // Scales down rather than overflowing on the narrowest phones.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (balance != null) ...[
                      _WalletChip(balance: balance),
                      const SizedBox(width: MocoSpacing.xs),
                    ],
                    const _Bell(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Same chrome as Discovery's Audio/Video pill, with a sliding selected dot.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.selected, required this.onSelect});

  final WebTopItem? selected;
  final ValueChanged<WebTopItem> onSelect;

  static const double _segment = 30;

  @override
  Widget build(BuildContext context) {
    final index = selected?.index ?? 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MocoRadius.pill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          key: const Key('topbar_capsule'),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: MocoColors.surfaceGlass,
            borderRadius: BorderRadius.circular(MocoRadius.pill),
            border: Border.all(color: MocoColors.borderSubtle),
          ),
          child: SizedBox(
            width: _segment * WebTopItem.values.length,
            height: _segment,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: MocoDuration.sheet,
                  curve: Curves.easeOutCubic,
                  left: index * _segment,
                  top: 0,
                  width: _segment,
                  height: _segment,
                  child: AnimatedOpacity(
                    duration: MocoDuration.tab,
                    opacity: selected == null ? 0 : 1,
                    child: DecoratedBox(
                      key: const Key('topbar_indicator'),
                      decoration: BoxDecoration(
                        color: MocoColors.accentPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final item in WebTopItem.values)
                      _Segment(
                        key: Key('topbar_${item.name}'),
                        item: item,
                        selected: item == selected,
                        size: _segment,
                        onTap: () => onSelect(item),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.item,
    required this.selected,
    required this.size,
    required this.onTap,
  });

  final WebTopItem item;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Tooltip(
        message: item.label,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: size,
              height: size,
              child: TweenAnimationBuilder<Color?>(
                duration: MocoDuration.sheet,
                tween: ColorTween(
                  end: selected
                      ? MocoColors.textOnAccent
                      : MocoColors.textMuted,
                ),
                builder: (context, color, _) =>
                    Icon(item.icon, size: 15, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The signed-in user's coin balance (the same value Wallet shows); opens
/// the existing Wallet.
class _WalletChip extends StatelessWidget {
  const _WalletChip({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('topbar_wallet'),
        onTap: () => context.go(Routes.wallet),
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: MocoColors.surfaceGlass,
            borderRadius: BorderRadius.circular(MocoRadius.pill),
            border: Border.all(color: MocoColors.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.circle, size: 12, color: MocoColors.coinAccent),
              const SizedBox(width: 5),
              Text(
                '$balance',
                key: const Key('topbar_wallet_balance'),
                style: TextStyle(
                  color: MocoColors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bell extends ConsumerWidget {
  const _Bell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(
      notificationsControllerProvider.select((s) => s.unreadCount),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        MocoIconButton(
          key: const Key('topbar_notifications'),
          icon: Icons.notifications_none_rounded,
          size: 40,
          onPressed: () => context.push(Routes.notifications),
        ),
        if (unread > 0)
          Positioned(
            top: 3,
            right: 3,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: MocoColors.danger,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

/// Web only: the hamburger's glass sidebar, over existing routes only.
class WebSideDrawer extends ConsumerWidget {
  const WebSideDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final searchOpen = ref.watch(discoveryWebSearchOpenProvider);
    final name = ref.watch(
      authControllerProvider.select((s) => s.user?.displayName),
    );

    void openDiscovery({required bool search}) {
      ref.read(discoveryWebSearchOpenProvider.notifier).state = search;
      if (search) ref.read(discoveryWebSearchFocusProvider.notifier).state++;
      context.go(Routes.discovery);
    }

    final items = <_DrawerEntry>[
      _DrawerEntry(
        'home',
        'Home',
        Icons.home_rounded,
        location.startsWith(Routes.discovery) && !searchOpen,
        () => openDiscovery(search: false),
      ),
      _DrawerEntry(
        'search',
        'Search',
        Icons.search_rounded,
        location.startsWith(Routes.discovery) && searchOpen,
        () => openDiscovery(search: true),
      ),
      _DrawerEntry(
        'feed',
        'Feed',
        Icons.slow_motion_video_rounded,
        location.startsWith(Routes.feed),
        () => context.go(Routes.feed),
      ),
      _DrawerEntry(
        'wallet',
        'Wallet',
        Icons.account_balance_wallet_rounded,
        location.startsWith(Routes.wallet),
        () => context.go(Routes.wallet),
      ),
      _DrawerEntry(
        'chats',
        'Chat',
        Icons.chat_bubble_rounded,
        location.startsWith(Routes.chats),
        () => context.go(Routes.chats),
      ),
      _DrawerEntry(
        'profile',
        'Profile',
        Icons.person_rounded,
        location.startsWith(Routes.profile),
        () => context.go(Routes.profile),
      ),
      _DrawerEntry(
        'settings',
        'Settings',
        Icons.settings_rounded,
        false,
        () => context.push(Routes.appSettings),
      ),
    ];

    return Drawer(
      key: const Key('web_side_drawer'),
      width: 272,
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(MocoRadius.xl),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: MocoColors.surfaceGlass,
            border: Border(right: BorderSide(color: MocoColors.borderSubtle)),
          ),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(MocoSpacing.md),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MocoSpacing.sm,
                    MocoSpacing.sm,
                    MocoSpacing.sm,
                    MocoSpacing.lg,
                  ),
                  child: Text(
                    name == null || name.isEmpty ? 'Moco' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MocoColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final item in items)
                  _DrawerTile(
                    entry: item,
                    onTap: () {
                      Navigator.of(context).pop();
                      item.onTap();
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerEntry {
  const _DrawerEntry(this.id, this.label, this.icon, this.selected, this.onTap);

  final String id;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({required this.entry, required this.onTap});

  final _DrawerEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = entry.selected
        ? MocoColors.accentPrimary
        : MocoColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: MocoSpacing.xs),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('drawer_${entry.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(MocoRadius.md),
          child: AnimatedContainer(
            duration: MocoDuration.tab,
            padding: const EdgeInsets.symmetric(
              horizontal: MocoSpacing.md,
              vertical: MocoSpacing.md,
            ),
            decoration: BoxDecoration(
              color: entry.selected
                  ? MocoColors.accentPrimary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(MocoRadius.md),
            ),
            child: Row(
              children: [
                Icon(entry.icon, size: 20, color: color),
                const SizedBox(width: MocoSpacing.md),
                Text(
                  entry.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 14.5,
                    fontWeight: entry.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
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
