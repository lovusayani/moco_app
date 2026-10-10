import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_app_frame.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/live.dart';
import 'live_controller.dart';
import 'platform/live_platform.dart';
import 'widgets/live_model_card.dart';

/// Moco Live (web): the top bar's Live item.
///
/// Everything about it is driven by the backend: `GET /api/live/config`
/// decides whether Live is on, whether the 18+ gate shows, and the layout,
/// card fields and tap behaviour; `GET /api/live/models` supplies the models
/// in the backend's order (curation and geobans applied server-side). Any
/// Live failure stays inside this screen.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  @override
  void initState() {
    super.initState();
    // A grid of live cams wants the whole window on desktop, so the admin's
    // tablet/desktop column counts mean what they say.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => MocoAppFrame.fullBleedRequests.value++,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => MocoAppFrame.fullBleedRequests.value--,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(liveConfigProvider);
    return SafeArea(
      bottom: false,
      child: Padding(
        // Clears the web top bar.
        padding: const EdgeInsets.only(top: 64),
        child: config.when(
          loading: () => const _LiveLoading(key: Key('live_loading')),
          error: (e, _) => MocoErrorState(
            key: const Key('live_config_error'),
            title: 'Live could not load',
            message: e is ApiException ? e.message : 'Please try again.',
            onRetry: () => ref.invalidate(liveConfigProvider),
          ),
          data: (cfg) {
            if (!cfg.enabled) {
              return const _Centered(
                child: MocoEmptyState(
                  key: Key('live_unavailable'),
                  title: 'Live is unavailable',
                  message: 'Live isn’t available right now. Please check back later.',
                  icon: Icons.sensors_off_rounded,
                ),
              );
            }
            final confirmed = ref.watch(liveAgeConfirmedProvider);
            if (cfg.requireAgeConfirmation && !confirmed) {
              return const _AgeGate(key: Key('live_age_gate'));
            }
            return _LiveModels(config: cfg);
          },
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 96),
    child: Center(child: child),
  );
}

/// 18+ confirmation, in-app. Nothing loads behind it: the models request is
/// only made once this is confirmed. "Go back" leaves Live for Discover.
class _AgeGate extends ConsumerWidget {
  const _AgeGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Centered(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg),
          child: MocoGlassCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: MocoColors.accentGradient,
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '18+',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                ),
                const SizedBox(height: MocoSpacing.md),
                Text(
                  'Adults only',
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: MocoSpacing.sm),
                Text(
                  'Live shows streams from an external adult provider. '
                  'Confirm you are 18 or older to continue.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: MocoColors.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: MocoSpacing.lg),
                MocoPrimaryButton(
                  key: const Key('live_age_confirm'),
                  label: 'I’m 18 or older',
                  onPressed: () {
                    ref.read(appPreferencesProvider).setLiveAgeConfirmed(true);
                    ref.read(liveAgeConfirmedProvider.notifier).state = true;
                  },
                ),
                const SizedBox(height: MocoSpacing.sm),
                MocoSecondaryButton(
                  key: const Key('live_age_cancel'),
                  label: 'Go back',
                  onPressed: () => context.go(Routes.discovery),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveModels extends ConsumerWidget {
  const _LiveModels({required this.config});

  final LiveConfig config;

  void _open(BuildContext context, WidgetRef ref, LiveModel model) {
    if (config.clickBehavior == LiveClickBehavior.provider) {
      final url = model.destinationUrl;
      if (url == null || !openLiveDestination(url)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            key: Key('live_destination_unavailable'),
            content: Text('This stream can’t be opened right now.'),
          ),
        );
      }
      return;
    }
    ref.read(liveSelectedModelProvider.notifier).state = model;
    context.push(Routes.liveWatchPath(model.username), extra: model);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = liveModelsControllerProvider(config.pageSize);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);

    if (state.isLoading && state.models.isEmpty) {
      return _LiveLoading(layout: config.layout);
    }
    if (state.error != null && state.models.isEmpty) {
      return _Centered(
        child: MocoErrorState(
          key: const Key('live_error'),
          title: 'Live could not load',
          message: state.error!.message,
          onRetry: controller.refresh,
        ),
      );
    }
    if (!state.available) {
      return _Centered(
        child: MocoEmptyState(
          key: const Key('live_provider_unavailable'),
          title: 'Live is unavailable',
          message: 'The live provider isn’t reachable right now. Please try again later.',
          icon: Icons.sensors_off_rounded,
          action: MocoSecondaryButton(
            label: 'Try again',
            expand: false,
            onPressed: controller.refresh,
          ),
        ),
      );
    }
    if (state.isEmpty) {
      return _Centered(
        child: MocoEmptyState(
          key: const Key('live_empty'),
          title: 'Nobody is live right now',
          message: 'Check back soon — streams come and go all the time.',
          icon: Icons.sensors_rounded,
          action: MocoSecondaryButton(
            label: 'Refresh',
            expand: false,
            onPressed: controller.refresh,
          ),
        ),
      );
    }

    final layout = config.layout;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      color: MocoColors.accentPrimary,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final contentWidth = width > 1280 ? 1280.0 : width;
          final side = (width - contentWidth) / 2 + MocoSpacing.lg;
          final base = layout.columns.forWidth(width);
          final columns = switch (layout.preset) {
            LiveLayoutPreset.large => (base - 1).clamp(1, 6),
            LiveLayoutPreset.compact => (base + 1).clamp(1, 7),
            _ => base,
          };
          final large = layout.preset == LiveLayoutPreset.large;
          final compact = layout.preset == LiveLayoutPreset.compact;
          final models = state.models;
          final hero =
              layout.preset == LiveLayoutPreset.mixed && models.isNotEmpty;
          final rest = hero ? models.skip(1).toList() : models;

          Widget card(LiveModel m) => LiveModelCard(
            model: m,
            fields: config.card,
            layout: layout,
            large: large,
            compact: compact,
            onTap: () => _open(context, ref, m),
          );

          return CustomScrollView(
            key: const Key('live_scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  side,
                  MocoSpacing.sm,
                  side,
                  layout.gap,
                ),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      const LiveBadge(),
                      const SizedBox(width: MocoSpacing.sm),
                      Expanded(
                        child: Text(
                          '${models.length}${state.hasMore ? '+' : ''} live now',
                          key: const Key('live_count'),
                          style: TextStyle(
                            color: MocoColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      MocoIconButton(
                        key: const Key('live_refresh'),
                        icon: Icons.refresh_rounded,
                        size: 36,
                        onPressed: state.isLoading ? null : controller.refresh,
                      ),
                    ],
                  ),
                ),
              ),
              if (hero)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, 0, side, layout.gap),
                  sliver: SliverToBoxAdapter(
                    child: AspectRatio(
                      key: const Key('live_hero'),
                      // The mixed layout's lead card: a wide feature tile.
                      aspectRatio: width < 600 ? 4 / 3 : 21 / 9,
                      child: card(models.first),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: side),
                sliver: SliverGrid(
                  key: const Key('live_grid'),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: layout.gap,
                    crossAxisSpacing: layout.gap,
                    childAspectRatio: large
                        ? layout.aspectRatio * 0.78
                        : layout.aspectRatio,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => card(rest[i]),
                    childCount: rest.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MocoSpacing.lg,
                    MocoSpacing.lg,
                    MocoSpacing.lg,
                    110,
                  ),
                  child: Center(
                    child: state.isLoadingMore
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : state.loadMoreError != null
                        ? MocoSecondaryButton(
                            key: const Key('live_load_more_retry'),
                            label: 'Couldn’t load more — retry',
                            expand: false,
                            onPressed: controller.loadMore,
                          )
                        : state.hasMore
                        ? MocoSecondaryButton(
                            key: const Key('live_load_more'),
                            label: 'Load more',
                            expand: false,
                            onPressed: controller.loadMore,
                          )
                        : Text(
                            'That’s everyone live right now.',
                            style: TextStyle(
                              color: MocoColors.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LiveLoading extends StatelessWidget {
  const _LiveLoading({super.key, this.layout = const LiveLayout()});

  final LiveLayout layout;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => GridView.builder(
        key: const Key('live_skeleton'),
        padding: EdgeInsets.fromLTRB(
          MocoSpacing.lg,
          MocoSpacing.xl + 8,
          MocoSpacing.lg,
          110,
        ),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: layout.columns.forWidth(c.maxWidth),
          mainAxisSpacing: layout.gap,
          crossAxisSpacing: layout.gap,
          childAspectRatio: layout.aspectRatio,
        ),
        itemCount: 8,
        itemBuilder: (context, i) => MocoSkeleton(
          width: double.infinity,
          height: double.infinity,
          radius: layout.cornerRadius,
        ),
      ),
    );
  }
}
