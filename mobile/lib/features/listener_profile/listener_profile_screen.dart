import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calling/call_controller.dart';
import '../../core/calling/call_session.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/call.dart';
import '../../shared/models/listener.dart';
import '../safety/safety_actions_sheet.dart';
import 'listener_profile_controller.dart';

/// Content tabs.
///
/// The backend has no posts/photos/voice endpoints at all, so each tab renders
/// an honest empty state rather than invented content. The tab structure exists
/// so the screen matches the approved design and a later phase can fill it in.
enum ProfileTab { shots, posts, photos, voice }

class ListenerProfileScreen extends ConsumerStatefulWidget {
  const ListenerProfileScreen({super.key, required this.listenerId});

  final int? listenerId;

  @override
  ConsumerState<ListenerProfileScreen> createState() =>
      _ListenerProfileScreenState();
}

class _ListenerProfileScreenState extends ConsumerState<ListenerProfileScreen> {
  final _scrollController = ScrollController();
  ProfileTab _tab = ProfileTab.shots;
  bool _compactHeader = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final shouldCompact = _scrollController.offset > 220;
    if (shouldCompact != _compactHeader) {
      setState(() => _compactHeader = shouldCompact);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.listenerId;

    if (id == null) {
      return const Scaffold(
        body: MocoErrorState(
          title: 'Listener not found',
          message: 'That profile link looks invalid.',
          icon: Icons.person_off_rounded,
        ),
      );
    }

    final profile = ref.watch(listenerProfileProvider(id));

    return Scaffold(
      body: MocoBackground(
        ambience: MocoAmbience.rich,
        child: profile.when(
          loading: () => const _ProfileSkeleton(),
          error: (error, _) {
            final mapped = ApiErrorMapper.from(error);
            return SafeArea(
              child: MocoErrorState(
                key: const Key('listener_profile_error'),
                message: mapped.message,
                onRetry: () => ref.invalidate(listenerProfileProvider(id)),
              ),
            );
          },
          data: (listener) => _ProfileBody(
            listener: listener,
            scrollController: _scrollController,
            compactHeader: _compactHeader,
            tab: _tab,
            onTabChanged: (t) => setState(() => _tab = t),
          ),
        ),
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({
    required this.listener,
    required this.scrollController,
    required this.compactHeader,
    required this.tab,
    required this.onTabChanged,
  });

  final ListenerDetail listener;
  final ScrollController scrollController;
  final bool compactHeader;
  final ProfileTab tab;
  final ValueChanged<ProfileTab> onTabChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final similar = ref.watch(similarListenersProvider(listener));

    // The relations controller is seeded from the fetched profile and owns
    // follow/favourite state from then on. Reading it here — rather than the
    // fetched value — is what lets the follower count update the moment the
    // button is pressed, and roll back with it on failure.
    final current = ref.watch(listenerRelationsProvider(listener));

    return Stack(
      children: [
        ListView(
          controller: scrollController,
          padding: EdgeInsets.zero,
          children: [
            _Hero(listener: current),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MocoSpacing.screenPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: MocoSpacing.lg),
                  _ActionRow(listener: listener),
                  const SizedBox(height: MocoSpacing.xl),
                  if ((listener.bio ?? '').trim().isNotEmpty) ...[
                    const MocoSectionHeader(title: 'About'),
                    const SizedBox(height: MocoSpacing.sm),
                    Text(
                      listener.bio!.trim(),
                      style: const TextStyle(
                        color: MocoColors.textSecondary,
                        fontSize: 14.5,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: MocoSpacing.xl),
                  ],
                  if (listener.languages.isNotEmpty) ...[
                    const MocoSectionHeader(title: 'Speaks'),
                    const SizedBox(height: MocoSpacing.sm),
                    Wrap(
                      spacing: MocoSpacing.sm,
                      runSpacing: MocoSpacing.sm,
                      children: listener.languages
                          .map((l) => MocoChip(label: _languageLabel(l)))
                          .toList(),
                    ),
                    const SizedBox(height: MocoSpacing.xl),
                  ],
                  _ProfileTabs(current: tab, onChanged: onTabChanged),
                  const SizedBox(height: MocoSpacing.lg),
                  // Honest empty content: no backend exists for these tabs.
                  SizedBox(
                    // MocoEmptyState needs ~200 at its natural size; 180 clipped
                    // it by a pixel on every width.
                    height: 208,
                    child: MocoEmptyState(
                      key: Key('profile_tab_${tab.name}'),
                      icon: Icons.photo_library_outlined,
                      title: 'Nothing here yet',
                      message: '${_tabLabel(tab)} arrive in a later phase.',
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.xl),
                  const MocoSectionHeader(title: 'Similar listeners'),
                  const SizedBox(height: MocoSpacing.md),
                  SizedBox(
                    height: 104,
                    child: similar.when(
                      loading: () => const Row(
                        children: [
                          MocoSkeleton(width: 68, height: 68, radius: 34),
                          SizedBox(width: MocoSpacing.md),
                          MocoSkeleton(width: 68, height: 68, radius: 34),
                          SizedBox(width: MocoSpacing.md),
                          MocoSkeleton(width: 68, height: 68, radius: 34),
                        ],
                      ),
                      error: (_, __) => const SizedBox.shrink(),
                      data: (items) => items.isEmpty
                          ? const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'No similar listeners online right now.',
                                style: TextStyle(
                                  color: MocoColors.textMuted,
                                  fontSize: 13.5,
                                ),
                              ),
                            )
                          : ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: MocoSpacing.md),
                              itemBuilder: (context, i) {
                                final item = items[i];
                                return GestureDetector(
                                  onTap: () =>
                                      context.replace('/listener/${item.id}'),
                                  child: Column(
                                    children: [
                                      MocoAvatar(
                                        name: item.name,
                                        imageUrl: item.avatarUrl,
                                        size: 64,
                                        ring: item.isAvailable,
                                      ),
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        width: 68,
                                        child: Text(
                                          item.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: MocoColors.textSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 140),
                ],
              ),
            ),
          ],
        ),

        // Compact header, revealed on scroll.
        AnimatedOpacity(
          opacity: compactHeader ? 1 : 0,
          duration: MocoDuration.tab,
          child: IgnorePointer(
            ignoring: !compactHeader,
            child: _CompactHeader(listener: listener),
          ),
        ),

        // Back control stays available at any scroll position.
        Positioned(
          top: MediaQuery.of(context).padding.top + MocoSpacing.sm,
          left: MocoSpacing.md,
          child: MocoIconButton(
            key: const Key('listener_profile_back'),
            icon: Icons.arrow_back_rounded,
            onPressed: () => context.pop(),
          ),
        ),

        // Report/block, the same sheet Chat Thread and the Feed use.
        Positioned(
          top: MediaQuery.of(context).padding.top + MocoSpacing.sm,
          right: MocoSpacing.md,
          child: MocoIconButton(
            key: const Key('listener_profile_more'),
            icon: Icons.more_horiz_rounded,
            tooltip: 'Report or block',
            onPressed: () => showSafetyActionsSheet(
              context: context,
              ref: ref,
              userId: listener.id,
              userName: listener.name,
            ),
          ),
        ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _CallBar(
            listener: listener,
            freeCall: user?.freeTrialAvailable ?? false,
          ),
        ),
      ],
    );
  }

  static String _languageLabel(String code) => switch (code) {
    'hi' => 'हिंदी',
    'te' => 'తెలుగు',
    'en' => 'English',
    _ => code,
  };

  static String _tabLabel(ProfileTab tab) => switch (tab) {
    ProfileTab.shots => 'Shots',
    ProfileTab.posts => 'Posts',
    ProfileTab.photos => 'Photos',
    ProfileTab.voice => 'Voice notes',
  };
}

class _Hero extends StatelessWidget {
  const _Hero({required this.listener});

  final ListenerDetail listener;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 64,
        left: MocoSpacing.screenPadding,
        right: MocoSpacing.screenPadding,
      ),
      child: Column(
        children: [
          MocoAvatar(
            name: listener.name,
            imageUrl: listener.avatarUrl,
            size: 128,
            ring: listener.isAvailable,
          ),
          const SizedBox(height: MocoSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  listener.name,
                  key: const Key('profile_hero_name'),
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              if (listener.verified) ...[
                const SizedBox(width: 6),
                const MocoVerifiedBadge(size: 20),
              ],
            ],
          ),
          const SizedBox(height: MocoSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              MocoOnlineDot(online: listener.isAvailable),
              const SizedBox(width: 6),
              Text(
                listener.isBusy
                    ? 'On another call'
                    : listener.isOnline
                    ? 'Available now'
                    : 'Offline',
                style: TextStyle(
                  color: listener.isAvailable
                      ? MocoColors.online
                      : MocoColors.textMuted,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: MocoSpacing.lg),
          // Three stats with fixed-width dividers overflowed a 360px screen
          // once follower counts reached four digits. Each stat now takes an
          // equal share and truncates, so the row fits at any width.
          Row(
            children: [
              Expanded(
                child: _Stat(
                  value: listener.rating > 0
                      ? listener.rating.toStringAsFixed(1)
                      : '—',
                  label: listener.ratingCount == 1
                      ? '1 rating'
                      : '${listener.ratingCount} ratings',
                ),
              ),
              const _StatDivider(),
              Expanded(
                child: _Stat(
                  value: '${listener.totalCalls}',
                  label: 'calls taken',
                ),
              ),
              const _StatDivider(),
              Expanded(
                child: _Stat(
                  value: '${listener.followerCount}',
                  label: listener.followerCount == 1 ? 'follower' : 'followers',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 30,
      color: MocoColors.borderSubtle,
      margin: const EdgeInsets.symmetric(horizontal: MocoSpacing.md),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: MocoColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(color: MocoColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader({required this.listener});

  final ListenerDetail listener;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + MocoSpacing.sm,
        bottom: MocoSpacing.md,
        left: 72,
        right: MocoSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: MocoColors.backgroundPrimary.withValues(alpha: 0.92),
        border: const Border(
          bottom: BorderSide(color: MocoColors.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          MocoAvatar(
            name: listener.name,
            imageUrl: listener.avatarUrl,
            size: 32,
          ),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Text(
              listener.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          MocoOnlineDot(online: listener.isAvailable),
        ],
      ),
    );
  }
}

/// Favourite / Follow / Chat.
///
/// Favourite and follow are real, backend-persisted and idempotent. They update
/// optimistically and roll back on failure — nothing is stored locally, so a
/// rollback means the action genuinely did not happen.
///
/// Chat has real endpoints but no UI until Phase 3, so it stays disabled.
class _ActionRow extends ConsumerWidget {
  const _ActionRow({required this.listener});

  final ListenerDetail listener;

  Future<void> _run(
    BuildContext context,
    Future<ApiException?> Function() action,
  ) async {
    final error = await action();
    if (error == null || !context.mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(listenerRelationsProvider(listener));
    final controller = ref.read(listenerRelationsProvider(listener).notifier);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MocoIconButton(
          key: const Key('action_favorite'),
          icon: current.isFavorited
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          active: current.isFavorited,
          tooltip: current.isFavorited
              ? 'Remove from favourites'
              : 'Add to favourites',
          onPressed: () => _run(context, controller.toggleFavorite),
        ),
        const SizedBox(width: MocoSpacing.lg),
        MocoIconButton(
          key: const Key('action_follow'),
          icon: current.isFollowing
              ? Icons.person_remove_alt_1_outlined
              : Icons.person_add_alt_1_outlined,
          active: current.isFollowing,
          tooltip: current.isFollowing ? 'Unfollow' : 'Follow',
          onPressed: () => _run(context, controller.toggleFollow),
        ),
        const SizedBox(width: MocoSpacing.lg),
        const MocoIconButton(
          key: Key('action_chat'),
          icon: Icons.chat_bubble_outline_rounded,
          tooltip: 'Chat arrives in Phase 3',
          onPressed: null,
        ),
      ],
    );
  }
}

class _ProfileTabs extends StatelessWidget {
  const _ProfileTabs({required this.current, required this.onChanged});

  final ProfileTab current;
  final ValueChanged<ProfileTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final tab in ProfileTab.values) ...[
            MocoChip(
              key: Key('profile_tab_chip_${tab.name}'),
              label: switch (tab) {
                ProfileTab.shots => 'Shots',
                ProfileTab.posts => 'Posts',
                ProfileTab.photos => 'Photos',
                ProfileTab.voice => 'Voice',
              },
              selected: current == tab,
              onTap: () => onChanged(tab),
            ),
            const SizedBox(width: MocoSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Call CTAs.
///
/// Tapping either button starts a REAL call: `initiateCall` runs the
/// server-side pre-flight balance check and atomically claims the listener —
/// this widget makes no availability or balance decision of its own, it only
/// reacts to what the call controller reports back.
class _CallBar extends ConsumerWidget {
  const _CallBar({required this.listener, required this.freeCall});

  final ListenerDetail listener;
  final bool freeCall;

  Future<void> _call(
    BuildContext context,
    WidgetRef ref,
    CallType type,
  ) async {
    final controller = ref.read(callControllerProvider.notifier);
    await controller.initiateCall(listener: listener, type: type);
    if (!context.mounted) return;

    final session = ref.read(callControllerProvider);
    if (session.phase == CallPhase.ringing) {
      context.push(Routes.callOutgoing);
      return;
    }

    // initiateCall() already turned this into a typed ApiException — surface
    // its human-readable message rather than inventing our own copy.
    final message = session.error?.message ?? 'Could not start the call.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBusy = ref.watch(
      callControllerProvider.select((s) => s.isBusy && s.phase == CallPhase.initiating),
    );
    final enabled = listener.isAvailable && !isBusy;

    return Container(
      padding: EdgeInsets.fromLTRB(
        MocoSpacing.screenPadding,
        MocoSpacing.md,
        MocoSpacing.screenPadding,
        MediaQuery.of(context).padding.bottom + MocoSpacing.md,
      ),
      decoration: BoxDecoration(
        color: MocoColors.backgroundPrimary.withValues(alpha: 0.94),
        border: const Border(top: BorderSide(color: MocoColors.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (freeCall)
            Padding(
              padding: const EdgeInsets.only(bottom: MocoSpacing.sm),
              child: Text(
                'Your first minute is free',
                style: TextStyle(
                  color: MocoColors.coinAccent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          // Only offer a call type this listener actually accepts — offering
          // video to someone who does not take video fails at call time.
          Row(
            children: [
              if (listener.acceptsAudio)
                Expanded(
                  child: MocoSecondaryButton(
                    key: const Key('cta_audio_call'),
                    label: 'Audio · ${listener.audioRate}/min',
                    icon: Icons.call_rounded,
                    onPressed: enabled
                        ? () => _call(context, ref, CallType.audio)
                        : null,
                  ),
                ),
              if (listener.acceptsAudio && listener.acceptsVideo)
                const SizedBox(width: MocoSpacing.md),
              if (listener.acceptsVideo)
                Expanded(
                  child: MocoPrimaryButton(
                    key: const Key('cta_video_call'),
                    label: 'Video · ${listener.videoRate}/min',
                    icon: Icons.videocam_rounded,
                    onPressed: enabled
                        ? () => _call(context, ref, CallType.video)
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(MocoSpacing.screenPadding),
        child: Column(
          children: [
            const SizedBox(height: 56),
            const MocoSkeleton(width: 128, height: 128, radius: 64),
            const SizedBox(height: MocoSpacing.lg),
            const MocoSkeleton(width: 150, height: 22),
            const SizedBox(height: MocoSpacing.sm),
            const MocoSkeleton(width: 100, height: 14),
            const SizedBox(height: MocoSpacing.xxl),
            const MocoSkeleton(height: 70, radius: MocoRadius.lg),
            const SizedBox(height: MocoSpacing.lg),
            const MocoSkeleton(height: 120, radius: MocoRadius.lg),
          ],
        ),
      ),
    );
  }
}
