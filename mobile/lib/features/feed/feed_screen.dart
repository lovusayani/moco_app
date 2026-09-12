import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_states.dart';
import '../../shared/models/feed.dart';
import 'feed_controller.dart';
import 'widgets/feed_post_item.dart';
import 'widgets/post_actions_sheet.dart';

/// The Feed: a vertical, full-screen, snapping page view.
///
/// Video playback is driven entirely by two facts this widget owns — which
/// page is current, and whether the app is in the foreground. Their `&&` is
/// handed to exactly one item as `isActive`, so "only the visible video plays"
/// and "background pauses playback" are the same rule rather than two
/// mechanisms that can disagree.
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();

  int _currentPage = 0;
  bool _isForeground = true;

  /// Start fetching the next page this many items before the end, so a fast
  /// scroller does not hit a spinner. Small on purpose — prefetching further
  /// ahead on a metered connection spends the user's data on posts they may
  /// never reach.
  static const _prefetchThreshold = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _isForeground) return;
    // Rebuilding with isActive false is what stops playback — the video widget
    // disposes its controller rather than holding a paused one in the
    // background, where the OS may reclaim it anyway.
    setState(() => _isForeground = foreground);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index, FeedState state) {
    setState(() => _currentPage = index);
    if (index >= state.posts.length - _prefetchThreshold) {
      ref.read(feedControllerProvider.notifier).loadMore();
    }
  }

  Future<void> _refresh() async {
    // Jump home first: refreshing under the user's finger while they are
    // deep in the feed would otherwise leave them on an arbitrary post.
    if (_pageController.hasClients && _currentPage != 0) {
      _pageController.jumpToPage(0);
    }
    setState(() => _currentPage = 0);
    await ref.read(feedControllerProvider.notifier).load();
  }

  void _openAuthor(Post post) {
    // Only listeners have a profile screen. FeedPostItem is given a null
    // callback otherwise, so this is never reached for a non-listener.
    context.push(Routes.listenerPath(post.author.id));
  }

  Future<void> _openActions(Post post) async {
    final myUserId = ref.read(authControllerProvider).user?.id;
    await showPostActionsSheet(
      context: context,
      ref: ref,
      post: post,
      // Your own post offers Delete; someone else's offers Report and Block.
      isOwnPost: myUserId != null && myUserId == post.author.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(feedControllerProvider);
    final controller = ref.read(feedControllerProvider.notifier);

    return Stack(
      children: [
        Positioned.fill(child: _body(state, controller)),
        // Compose sits above the feed rather than in the tab bar: the bottom
        // navigation's labels, order and actions are Phase 1's and are not
        // being changed here.
        Positioned(
          right: MocoSpacing.screenPadding,
          top: MediaQuery.paddingOf(context).top + MocoSpacing.sm,
          child: const _ComposeButton(),
        ),
      ],
    );
  }

  Widget _body(FeedState state, FeedController controller) {
    if (state.isLoading && state.posts.isEmpty) {
      return const _FeedLoading(key: Key('feed_loading'));
    }

    if (state.isFatalError) {
      return MocoErrorState(
        key: const Key('feed_error'),
        message: ApiErrorMapper.from(state.error!).message,
        onRetry: controller.load,
      );
    }

    if (state.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        color: MocoColors.accentPrimary,
        child: ListView(
          key: const Key('feed_empty_scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.22),
            const MocoEmptyState(
              key: Key('feed_empty'),
              title: 'Nothing here yet',
              message: 'Posts from people on Moco will show up here. '
                  'Be the first to share something.',
              icon: Icons.dynamic_feed_outlined,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      color: MocoColors.accentPrimary,
      child: PageView.builder(
        key: const Key('feed_pager'),
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: state.posts.length,
        onPageChanged: (index) => _onPageChanged(index, state),
        itemBuilder: (context, index) {
          final post = state.posts[index];
          return FeedPostItem(
            // Keyed by post id, not index, so a prepend or a removal cannot
            // hand one post's state (a live video controller in particular)
            // to a different post.
            key: ValueKey(post.id),
            post: post,
            isActive: index == _currentPage && _isForeground,
            onAuthorTap:
                post.author.isListener ? () => _openAuthor(post) : null,
            onMoreTap: () => _openActions(post),
          );
        },
      ),
    );
  }
}

class _ComposeButton extends StatelessWidget {
  const _ComposeButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Create a post',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('feed_compose_button'),
          onTap: () => context.push(Routes.postCompose),
          customBorder: const CircleBorder(),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: MocoColors.accentGradient,
              boxShadow: [
                BoxShadow(
                  color: MocoColors.accentPrimary.withValues(alpha: 0.35),
                  blurRadius: 16,
                ),
              ],
            ),
            child: const Icon(
              Icons.add_rounded,
              color: MocoColors.textOnAccent,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-bleed skeleton, shaped like the post it is standing in for so the
/// first real page does not visibly re-lay-out on arrival.
class _FeedLoading extends StatelessWidget {
  const _FeedLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: MocoColors.backgroundPrimary),
        Positioned(
          left: MocoSpacing.screenPadding,
          right: MocoSpacing.screenPadding,
          bottom: 96,
          child: Row(
            children: [
              const MocoSkeleton(width: 42, height: 42, radius: 21),
              const SizedBox(width: MocoSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  MocoSkeleton(width: 130, height: 14),
                  SizedBox(height: 8),
                  MocoSkeleton(width: 90, height: 11),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
