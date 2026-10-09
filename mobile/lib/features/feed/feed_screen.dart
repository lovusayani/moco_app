import 'dart:async';

import 'package:flutter/gestures.dart';
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
import 'feed_preferences.dart';
import 'share/feed_share.dart';
import 'widgets/comments_sheet.dart';
import 'widgets/feed_post_item.dart';
import 'widgets/post_actions_sheet.dart';

/// The Feed: a vertical, full-screen, snapping page view.
///
/// Video playback is driven entirely by two facts this widget owns — which
/// page is current, and whether the app is in the foreground. Their `&&` is
/// handed to exactly one item as `isActive`, so "only the visible video plays"
/// and "background pauses playback" are the same rule rather than two
/// mechanisms that can disagree.
///
/// Auto-scroll (App settings → Feed auto-scroll, off by default) is also
/// decided here, in one place: when it is on, a video moves on when it ends
/// and a photo after [imageAutoAdvance]. Any touch, click, drag or wheel on
/// the Feed pauses it for the rest of this visit — the saved setting is never
/// touched — and leaving the Feed and coming back starts a new visit.
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key, this.initialPostId});

  /// From a shared link (`/feed?post=<id>`): open on this post.
  final int? initialPostId;

  /// How long a photo stays up while auto-scrolling.
  static const imageAutoAdvance = Duration(seconds: 5);

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

  // --- auto-scroll -----------------------------------------------------------

  /// The user touched the Feed during this visit. Cleared only by a new visit
  /// (or the Resume chip) — never written to the saved setting.
  bool _pausedThisVisit = false;

  /// Sheets this screen opened (comments, post actions) that are still up.
  int _openSheets = 0;

  /// Whether the Feed is on screen: not covered by a pushed route.
  bool _visible = true;

  Timer? _imageTimer;
  int? _imageTimerPostId;

  /// The end of the list was reached while auto-scrolling; advance once the
  /// next page arrives.
  bool _advanceWhenLoaded = false;

  bool get _autoScrolling =>
      ref.read(feedAutoScrollProvider) &&
      !_pausedThisVisit &&
      _openSheets == 0 &&
      _isForeground &&
      _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final postId = widget.initialPostId;
    if (postId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLinked(postId));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covered by a pushed route (a profile, the composer) → not visible.
    // Coming back is a new visit: auto-scroll resumes if the setting is on.
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _pausedThisVisit = false;
    } else {
      _cancelImageTimer();
    }
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
    _cancelImageTimer();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _openLinked(int postId) async {
    final found = await ref
        .read(feedControllerProvider.notifier)
        .openPost(postId);
    if (!mounted) return;
    if (!found) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          key: Key('feed_link_missing'),
          content: Text('That post is no longer available'),
        ),
      );
      return;
    }
    // The linked post is pinned first.
    if (_pageController.hasClients && _currentPage != 0) {
      _pageController.jumpToPage(0);
    }
    setState(() => _currentPage = 0);
  }

  void _onPageChanged(int index, FeedState state) {
    setState(() => _currentPage = index);
    if (index >= state.visiblePosts.length - _prefetchThreshold) {
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
    final controller = ref.read(feedControllerProvider.notifier);
    controller.clearPinned();
    await controller.load();
  }

  // --- auto-scroll engine ----------------------------------------------------

  /// Any pointer down, wheel or trackpad gesture on the Feed.
  void _onUserInteraction() {
    _cancelImageTimer();
    _advanceWhenLoaded = false;
    if (!_pausedThisVisit) setState(() => _pausedThisVisit = true);
  }

  void _cancelImageTimer() {
    _imageTimer?.cancel();
    _imageTimer = null;
    _imageTimerPostId = null;
  }

  /// Keeps the photo timer in line with what is on screen. Idempotent: called
  /// on every build, it only starts a timer for a photo that lacks one.
  void _syncImageTimer(List<Post> posts) {
    final post = _currentPage < posts.length ? posts[_currentPage] : null;
    // A video advances on completion; a post with nothing to play (missing
    // media) is timed like a photo so it cannot stall the feed.
    final timed = post != null && !(post.isVideo && post.hasMedia);
    if (!_autoScrolling || !timed) {
      _cancelImageTimer();
      return;
    }
    if (_imageTimer != null && _imageTimerPostId == post.id) return;
    _cancelImageTimer();
    _imageTimerPostId = post.id;
    _imageTimer = Timer(FeedScreen.imageAutoAdvance, () {
      _imageTimer = null;
      _imageTimerPostId = null;
      _advance(fromPostId: post.id);
    });
  }

  /// Moves exactly one post on, if auto-scroll is still running and the
  /// post that asked is still the current one.
  void _advance({required int fromPostId}) {
    if (!mounted || !_autoScrolling) return;
    final state = ref.read(feedControllerProvider);
    final posts = state.visiblePosts;
    if (_currentPage >= posts.length || posts[_currentPage].id != fromPostId) {
      return;
    }
    if (_currentPage < posts.length - 1) {
      _pageController.animateToPage(
        _currentPage + 1,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    } else if (state.hasMore) {
      _advanceWhenLoaded = true;
      ref.read(feedControllerProvider.notifier).loadMore();
    }
    // Otherwise this is the last post: stay on it.
  }

  /// A sheet opened from the Feed: auto-scroll waits while it is up.
  Future<T> _withSheet<T>(Future<T> Function() open) async {
    _cancelImageTimer();
    setState(() => _openSheets += 1);
    try {
      return await open();
    } finally {
      if (mounted) setState(() => _openSheets -= 1);
    }
  }

  // --- actions ---------------------------------------------------------------

  void _openAuthor(Post post) {
    // Only listeners have a profile screen. FeedPostItem is given a null
    // callback otherwise, so this is never reached for a non-listener.
    context.push(Routes.listenerPath(post.author.id));
  }

  Future<void> _openActions(Post post) {
    final myUserId = ref.read(authControllerProvider).user?.id;
    return _withSheet(
      () => showPostActionsSheet(
        context: context,
        ref: ref,
        post: post,
        // Your own post offers Delete; someone else's offers Report and Block.
        isOwnPost: myUserId != null && myUserId == post.author.id,
      ),
    );
  }

  Future<void> _openComments(Post post) {
    final controller = ref.read(feedControllerProvider.notifier);
    return _withSheet(
      () => showCommentsSheet(
        context: context,
        post: post,
        onCountChanged: (count) => controller.setCommentCount(post.id, count),
      ),
    );
  }

  Future<void> _follow(Post post) async {
    try {
      await ref.read(feedControllerProvider.notifier).toggleFollow(post.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(ApiErrorMapper.from(e).message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(feedControllerProvider);
    final controller = ref.read(feedControllerProvider.notifier);
    final autoScrollSetting = ref.watch(feedAutoScrollProvider);
    final posts = state.visiblePosts;

    _syncImageTimer(posts);
    if (_advanceWhenLoaded && _currentPage < posts.length - 1) {
      _advanceWhenLoaded = false;
      final from = posts[_currentPage].id;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _advance(fromPostId: from),
      );
    }

    return Listener(
      // Translucent: observe every touch without taking it from the feed.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onUserInteraction(),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) _onUserInteraction();
      },
      onPointerPanZoomStart: (_) => _onUserInteraction(),
      child: Stack(
        children: [
          Positioned.fill(child: _body(state, controller)),
          // With no posts there is no action stack, so the composer is
          // reached from the corner instead.
          if (posts.isEmpty)
            Positioned(
              right: MocoSpacing.screenPadding,
              top: MediaQuery.paddingOf(context).top + MocoSpacing.sm,
              child: const _ComposeButton(),
            ),
          if (autoScrollSetting && _pausedThisVisit && posts.isNotEmpty)
            Positioned(
              top: MediaQuery.paddingOf(context).top + MocoSpacing.md,
              left: 0,
              right: 0,
              child: Center(
                child: _AutoScrollPausedChip(
                  onResume: () => setState(() => _pausedThisVisit = false),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(FeedState state, FeedController controller) {
    final posts = state.visiblePosts;

    if (state.isLoading && posts.isEmpty) {
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
              message:
                  'Posts from people on Moco will show up here. '
                  'Be the first to share something.',
              icon: Icons.dynamic_feed_outlined,
            ),
          ],
        ),
      );
    }

    final autoScrolling = _autoScrolling;

    return RefreshIndicator(
      onRefresh: _refresh,
      color: MocoColors.accentPrimary,
      child: PageView.builder(
        key: const Key('feed_pager'),
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: posts.length,
        onPageChanged: (index) => _onPageChanged(index, state),
        itemBuilder: (context, index) {
          final post = posts[index];
          final isCurrent = index == _currentPage;
          return FeedPostItem(
            // Keyed by post id, not index, so a prepend or a removal cannot
            // hand one post's state (a live video controller in particular)
            // to a different post.
            key: ValueKey(post.id),
            post: post,
            isActive: isCurrent && _isForeground,
            onAuthorTap: post.author.isListener
                ? () => _openAuthor(post)
                : null,
            onMoreTap: () => _openActions(post),
            onCompose: () => context.push(Routes.postCompose),
            onFollow: post.author.canFollow ? () => _follow(post) : null,
            onLike: () => controller.toggleLike(post.id),
            onComment: () => _openComments(post),
            onShare: () =>
                shareFeedPost(context: context, ref: ref, post: post),
            // Auto-scroll plays a clip once, then moves on.
            loopVideo: !(autoScrolling && isCurrent),
            onVideoCompleted: () => _advance(fromPostId: post.id),
          );
        },
      ),
    );
  }
}

class _AutoScrollPausedChip extends StatelessWidget {
  const _AutoScrollPausedChip({required this.onResume});

  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('feed_autoscroll_resume'),
        onTap: onResume,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(MocoRadius.pill),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.pause_circle_outline_rounded,
                size: 16,
                color: Colors.white,
              ),
              SizedBox(width: 6),
              Text(
                'Auto-scroll paused · Resume',
                style: TextStyle(
                  color: Colors.white,
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
        ColoredBox(color: MocoColors.backgroundPrimary),
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
