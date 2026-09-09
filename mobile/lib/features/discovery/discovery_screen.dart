import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/listeners_api.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
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
                        Expanded(
                          child: MocoSectionHeader(
                            title: 'Discover',
                            subtitle: user?.displayName == null
                                ? null
                                : 'Hi ${user!.displayName}',
                          ),
                        ),
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
                          decoration: const InputDecoration(
                            hintText: 'Search loaded listeners',
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
                    _ModeToggle(
                      mode: state.mode,
                      onChanged: controller.setMode,
                    ),
                    const SizedBox(height: MocoSpacing.md),
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
                  title: 'No listeners found',
                  message:
                      state.filters.isActive || state.searchQuery.isNotEmpty
                      ? 'Try clearing your filters or search.'
                      : 'Nobody is available right now. Pull down to refresh.',
                  action: state.filters.isActive
                      ? MocoSecondaryButton(
                          label: 'Clear filters',
                          expand: false,
                          onPressed: () =>
                              controller.setFilters(const DiscoveryFilters()),
                        )
                      : null,
                ),
              )
            else
              _ListenerGrid(
                listeners: state.visibleListeners,
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
          crossAxisCount: 2,
          mainAxisSpacing: MocoSpacing.md,
          crossAxisSpacing: MocoSpacing.md,
          childAspectRatio: 0.72,
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
          crossAxisCount: 2,
          mainAxisSpacing: MocoSpacing.md,
          crossAxisSpacing: MocoSpacing.md,
          childAspectRatio: 0.72,
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
          childCount: 6,
        ),
      ),
    );
  }
}

/// Audio/Video switch.
///
/// Changes which rate the cards display. It is NOT a capability filter — the
/// backend has no such flag (see the API gaps table in mobile/README.md).
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final CallMode mode;
  final ValueChanged<CallMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ModeButton(
            key: const Key('discovery_mode_audio'),
            label: 'Callers',
            icon: Icons.call_rounded,
            selected: mode == CallMode.audio,
            onTap: () => onChanged(CallMode.audio),
          ),
        ),
        const SizedBox(width: MocoSpacing.sm),
        Expanded(
          child: _ModeButton(
            key: const Key('discovery_mode_video'),
            label: 'Video',
            icon: Icons.videocam_rounded,
            selected: mode == CallMode.video,
            onTap: () => onChanged(CallMode.video),
          ),
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: MocoDuration.tab,
      height: MocoSpacing.minTouchTarget,
      decoration: BoxDecoration(
        color: selected
            ? MocoColors.accentPrimary.withValues(alpha: 0.16)
            : MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(
          color: selected ? MocoColors.accentPrimary : MocoColors.borderSubtle,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MocoRadius.md),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected
                    ? MocoColors.accentPrimary
                    : MocoColors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? MocoColors.textPrimary
                      : MocoColors.textSecondary,
                  fontSize: 14,
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
