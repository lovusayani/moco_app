import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/listeners_api.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/theme/moco_theme.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../notifications/notifications_controller.dart';
import 'discovery_controller.dart';
import 'widgets/listener_card.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Prefetch before the user hits the bottom so paging feels continuous.
    if (position.pixels >= position.maxScrollExtent - 400) {
      ref.read(discoveryControllerProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoveryControllerProvider);
    final controller = ref.read(discoveryControllerProvider.notifier);
    final user = ref.watch(authControllerProvider).user;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: controller.refresh,
        color: MocoColors.accentPrimary,
        backgroundColor: MocoColors.backgroundElevated,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  MocoSpacing.screenPadding,
                  MocoSpacing.md,
                  MocoSpacing.screenPadding,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // The leading group is the sole flexible child (an
                        // Expanded, not a Flexible competing with a Spacer)
                        // so it claims exactly the width left over after the
                        // fixed trailing icons — "Discover" only shrinks on
                        // the very narrowest supported screens, instead of
                        // splitting the row down the middle with empty space.
                        Expanded(
                          child: Row(
                            children: [
                              // A one-off serif treatment for this single
                              // wordmark — the reference's only departure
                              // from Inter — rather than reusing
                              // MocoSectionHeader, which every other screen
                              // also uses and must stay in the app's normal
                              // typeface.
                              const Flexible(
                                child: Text(
                                  'Discover',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: MocoTheme.discoverWordmarkFontFamily,
                                    color: MocoColors.textPrimary,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: MocoSpacing.xs),
                              _CompactModeToggle(
                                mode: state.mode,
                                onChanged: controller.setMode,
                              ),
                            ],
                          ),
                        ),
                        if (user != null) ...[
                          _CoinBalanceChip(balance: user.coinBalance),
                          const SizedBox(width: MocoSpacing.xs),
                        ],
                        const _NotificationsBell(),
                        const SizedBox(width: MocoSpacing.xs),
                        MocoIconButton(
                          key: const Key('discovery_search_toggle'),
                          icon: _searchOpen
                              ? Icons.close_rounded
                              : Icons.search_rounded,
                          active: _searchOpen,
                          onPressed: () {
                            setState(() => _searchOpen = !_searchOpen);
                            if (!_searchOpen) {
                              _searchController.clear();
                              controller.setSearchQuery('');
                            }
                          },
                        ),
                      ],
                    ),
                    AnimatedCrossFade(
                      duration: MocoDuration.sheet,
                      crossFadeState: _searchOpen
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      firstChild: const SizedBox(width: double.infinity),
                      secondChild: Padding(
                        padding: const EdgeInsets.only(top: MocoSpacing.md),
                        child: TextField(
                          key: const Key('discovery_search_field'),
                          controller: _searchController,
                          onChanged: controller.setSearchQuery,
                          style: const TextStyle(
                            color: MocoColors.textPrimary,
                            fontSize: 15,
                          ),
                          textInputAction: TextInputAction.search,
                          onSubmitted: controller.submitSearch,
                          decoration: const InputDecoration(
                            hintText: 'Search listeners',
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: MocoColors.textMuted,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: MocoSpacing.lg),
                    _FilterRow(
                      filters: state.filters,
                      onChanged: controller.setFilters,
                    ),
                    const SizedBox(height: MocoSpacing.lg),
                  ],
                ),
              ),
            ),
            if (state.isLoading)
              const _LoadingGrid()
            else if (state.error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: MocoErrorState(
                  key: const Key('discovery_error'),
                  message: state.error!.message,
                  onRetry: state.error!.isRetryable ? controller.refresh : null,
                ),
              )
            else if (state.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: MocoEmptyState(
                  key: const Key('discovery_empty'),
                  title: state.isEmptyFromSearch
                      ? 'No matches'
                      : 'No listeners found',
                  message: state.isEmptyFromSearch
                      ? 'Nobody matches "${state.searchQuery}". Try a different name.'
                      : state.filters.isActive
                      ? 'Try clearing your filters.'
                      : 'Nobody is available right now. Pull down to refresh.',
                  action: state.filters.isActive
                      ? MocoSecondaryButton(
                          label: 'Clear filters',
                          expand: false,
                          // Clearing filters must not silently drop the user's
                          // search term or the call-type toggle.
                          onPressed: () => controller.setFilters(
                            DiscoveryFilters(
                              query: state.filters.query,
                              callType: state.filters.callType,
                            ),
                          ),
                        )
                      : null,
                ),
              )
            else
              _ListenerGrid(
                listeners: state.listeners,
                showVideoRate: state.mode == CallMode.video,
                firstCallFree: user?.freeTrialAvailable ?? false,
              ),
            if (state.isLoadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(MocoSpacing.xl),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}

class _ListenerGrid extends StatelessWidget {
  const _ListenerGrid({
    required this.listeners,
    required this.showVideoRate,
    required this.firstCallFree,
  });

  final List listeners;
  final bool showVideoRate;
  final bool firstCallFree;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.screenPadding,
      ),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: MocoSpacing.sm,
          crossAxisSpacing: MocoSpacing.sm,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final listener = listeners[index];
          return ListenerCard(
            key: Key('listener_card_${listener.id}'),
            listener: listener,
            showVideoRate: showVideoRate,
            firstCallFree: firstCallFree,
            onTap: () => context.push(Routes.listenerPath(listener.id as int)),
          );
        }, childCount: listeners.length),
      ),
    );
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.screenPadding,
      ),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: MocoSpacing.sm,
          crossAxisSpacing: MocoSpacing.sm,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => const MocoGlassCard(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MocoSkeleton(width: 84, height: 84, radius: 42),
                SizedBox(height: MocoSpacing.md),
                MocoSkeleton(width: 80, height: 13),
                SizedBox(height: MocoSpacing.sm),
                MocoSkeleton(width: 54, height: 11),
              ],
            ),
          ),
          childCount: 9,
        ),
      ),
    );
  }
}

/// Audio/Video switch, as a compact icon-only pill next to the header
/// wordmark — matching the reference's placement and chrome.
///
/// This reaches the backend as a real capability filter (`callType` on
/// `GET /listeners`, unchanged) — it is not just a client-side relabel, and
/// this restyle changes nothing about that.
class _CompactModeToggle extends StatelessWidget {
  const _CompactModeToggle({required this.mode, required this.onChanged});

  final CallMode mode;
  final ValueChanged<CallMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CompactModeSegment(
            key: const Key('discovery_mode_audio'),
            icon: Icons.call_rounded,
            selected: mode == CallMode.audio,
            onTap: () => onChanged(CallMode.audio),
          ),
          _CompactModeSegment(
            key: const Key('discovery_mode_video'),
            icon: Icons.videocam_rounded,
            selected: mode == CallMode.video,
            onTap: () => onChanged(CallMode.video),
          ),
        ],
      ),
    );
  }
}

class _CompactModeSegment extends StatelessWidget {
  const _CompactModeSegment({
    super.key,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? MocoColors.accentPrimary : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 14,
            color: selected ? MocoColors.textOnAccent : MocoColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Coin balance shown right in the Discovery header — reads the same
/// `coinBalance` the Wallet tab shows, already on the signed-in user, so
/// nothing new is fetched for it.
class _CoinBalanceChip extends StatelessWidget {
  const _CoinBalanceChip({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.circle,
            size: 12,
            color: MocoColors.coinAccent,
          ),
          const SizedBox(width: 5),
          Text(
            '$balance',
            style: const TextStyle(
              color: MocoColors.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Filters that the backend genuinely supports: online, language, gender.
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.filters, required this.onChanged});

  final DiscoveryFilters filters;
  final ValueChanged<DiscoveryFilters> onChanged;

  static const _languages = {'en': 'English', 'hi': 'हिंदी', 'te': 'తెలుగు'};
  static const _genders = {'female': 'Female', 'male': 'Male'};

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          MocoChip(
            key: const Key('filter_online'),
            label: 'Online now',
            icon: Icons.circle,
            selected: filters.onlineOnly,
            onTap: () =>
                onChanged(filters.copyWith(onlineOnly: !filters.onlineOnly)),
          ),
          const SizedBox(width: MocoSpacing.sm),
          for (final entry in _languages.entries) ...[
            MocoChip(
              key: Key('filter_lang_${entry.key}'),
              label: entry.value,
              selected: filters.language == entry.key,
              onTap: () => onChanged(
                filters.language == entry.key
                    ? filters.copyWith(clearLanguage: true)
                    : filters.copyWith(language: entry.key),
              ),
            ),
            const SizedBox(width: MocoSpacing.sm),
          ],
          for (final entry in _genders.entries) ...[
            MocoChip(
              key: Key('filter_gender_${entry.key}'),
              label: entry.value,
              selected: filters.gender == entry.key,
              onTap: () => onChanged(
                filters.gender == entry.key
                    ? filters.copyWith(clearGender: true)
                    : filters.copyWith(gender: entry.key),
              ),
            ),
            const SizedBox(width: MocoSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Reached from Discovery's header rather than a sixth bottom-nav tab — the
/// five tabs are fixed. Watching [notificationsControllerProvider] here
/// starts the inbox loading the moment Discovery is on screen, so the badge
/// is already current the first time a user notices it, and opening the
/// screen itself is instant (no extra fetch).
class _NotificationsBell extends ConsumerWidget {
  const _NotificationsBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(
      notificationsControllerProvider.select((s) => s.unreadCount),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        MocoIconButton(
          key: const Key('discovery_notifications_bell'),
          icon: Icons.notifications_none_rounded,
          onPressed: () => context.push(Routes.notifications),
        ),
        if (unread > 0)
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              key: const Key('discovery_notifications_badge'),
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: MocoColors.danger,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}
