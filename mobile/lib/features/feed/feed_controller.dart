import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/feed_api.dart';
import '../../core/api/listeners_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/feed.dart';

class FeedState {
  const FeedState({
    this.posts = const [],
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
    this.pinned,
  });

  /// Newest first, exactly as the server ordered them.
  final List<Post> posts;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final ApiException? error;

  /// A post opened from a shared link. Shown first, ahead of the feed, and
  /// never duplicated if the feed also contains it.
  final Post? pinned;

  /// What the pager shows: the pinned post (if any), then the feed.
  List<Post> get visiblePosts {
    final first = pinned;
    if (first == null) return posts;
    return [first, ...posts.where((p) => p.id != first.id)];
  }

  bool get isEmpty =>
      !isLoading && error == null && posts.isEmpty && pinned == null;

  /// An error with nothing to show is a full-screen retry; an error with posts
  /// already on screen must not blank the feed the user is looking at.
  bool get isFatalError => error != null && visiblePosts.isEmpty;

  FeedState copyWith({
    List<Post>? posts,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    ApiException? error,
    bool clearError = false,
    Post? pinned,
    bool clearPinned = false,
  }) {
    return FeedState(
      posts: posts ?? this.posts,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      pinned: clearPinned ? null : (pinned ?? this.pinned),
    );
  }
}

/// Owns the feed list and its pagination cursor.
///
/// The feed needs no realtime: a post is not time-critical the way a call or a
/// message is, so there is no socket subscription here and no second
/// connection. Pull-to-refresh and pagination are the whole update model.
class FeedController extends StateNotifier<FeedState> {
  FeedController(this._api, {this.listeners}) : super(const FeedState()) {
    load();
  }

  final FeedApi _api;

  /// The existing listener follow API — Follow in the feed is that follow,
  /// not a second system.
  final ListenersApi? listeners;

  /// The id of the last post held, sent as `cursor`. Null means "from the top".
  int? _cursor;

  /// Guards against a second page being requested while one is in flight —
  /// a snap feed fires the near-the-end check on every settle, so this is hit
  /// routinely rather than only in edge cases.
  bool _loadingPage = false;

  /// Merges by post id, keeping the server's newest-first order.
  ///
  /// Keyset pagination should never hand back a post the client already has,
  /// but a refresh racing a page load can, and a duplicate id in a PageView
  /// means a duplicated video controller. Deduping here makes that
  /// structurally impossible rather than unlikely.
  static List<Post> _mergeById(List<Post> existing, List<Post> incoming) {
    final byId = <int, Post>{};
    for (final post in [...existing, ...incoming]) {
      byId[post.id] = post;
    }
    final merged = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));
    return merged;
  }

  /// First page, or a full reload after an error or a pull-to-refresh.
  Future<void> load() async {
    if (_loadingPage) return;
    _loadingPage = true;
    state = state.copyWith(isLoading: state.posts.isEmpty, clearError: true);
    try {
      final page = await _api.feed();
      _cursor = page.nextCursor;
      state = state.copyWith(
        // Replace rather than merge: this is the newest page from the top, so
        // anything the client held that is not in it is either older (and will
        // come back through pagination) or deleted.
        posts: page.posts,
        hasMore: page.hasMore,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(error: e, isLoading: false);
    } finally {
      _loadingPage = false;
    }
  }

  /// The next older page. Safe to call repeatedly — it no-ops while a page is
  /// in flight and once the feed has ended.
  Future<void> loadMore() async {
    if (_loadingPage || !state.hasMore || state.isLoading) return;
    _loadingPage = true;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final page = await _api.feed(cursor: _cursor);
      _cursor = page.nextCursor;
      state = state.copyWith(
        posts: _mergeById(state.posts, page.posts),
        hasMore: page.hasMore,
        isLoadingMore: false,
      );
    } on ApiException catch (e) {
      // Keep the posts already on screen; the error is about the next page.
      state = state.copyWith(isLoadingMore: false, error: e);
    } finally {
      _loadingPage = false;
    }
  }

  /// Puts a just-published post at the top without a refetch, so Publish feels
  /// immediate. Deduped by id like every other insertion.
  void prepend(Post post) {
    state = state.copyWith(posts: _mergeById([post], state.posts));
  }

  /// Drops a post the user deleted or reported, so it disappears immediately
  /// rather than at the next refresh. The server is still what decides
  /// whether it is gone — this only reflects a call that already succeeded.
  void removeLocally(int postId) {
    state = state.copyWith(
      posts: state.posts.where((p) => p.id != postId).toList(),
      clearPinned: state.pinned?.id == postId,
    );
  }

  Post? postById(int postId) {
    for (final post in state.visiblePosts) {
      if (post.id == postId) return post;
    }
    return null;
  }

  /// Applies [change] to the post wherever it is held (feed and pinned).
  void _updatePost(int postId, Post Function(Post) change) {
    final pinned = state.pinned;
    state = state.copyWith(
      posts: [for (final p in state.posts) p.id == postId ? change(p) : p],
      pinned: pinned != null && pinned.id == postId ? change(pinned) : null,
    );
  }

  // --- a shared link ---------------------------------------------------------

  /// Loads one post for a shared link and pins it to the top. Returns false
  /// when it is gone (deleted, removed, or blocked either way).
  Future<bool> openPost(int postId) async {
    try {
      final post = await _api.post(postId);
      if (!mounted) return false;
      state = state.copyWith(pinned: post);
      return true;
    } on ApiException {
      return false;
    }
  }

  void clearPinned() => state = state.copyWith(clearPinned: true);

  // --- likes -----------------------------------------------------------------

  /// What the user last asked for, per post, while a request is in flight.
  final _likeWanted = <int, bool>{};
  final _likeInFlight = <int>{};

  /// Optimistic like toggle. Taps are applied at once; requests are sent one
  /// at a time per post, and a tap that lands while one is in flight is sent
  /// after it — so the server always ends on the user's last choice and the
  /// count is the server's, never double-counted.
  void toggleLike(int postId) {
    final post = postById(postId);
    if (post == null) return;
    final want = !post.liked;
    _updatePost(
      postId,
      (p) => p.copyWith(
        liked: want,
        likeCount: (p.likeCount + (want ? 1 : -1)).clamp(0, 1 << 31),
      ),
    );
    _likeWanted[postId] = want;
    if (!_likeInFlight.contains(postId)) _syncLike(postId);
  }

  Future<void> _syncLike(int postId) async {
    _likeInFlight.add(postId);
    try {
      while (true) {
        final want = _likeWanted[postId]!;
        final result = await _api.setLiked(postId, liked: want);
        if (!mounted) return;
        if (_likeWanted[postId] == want) {
          _updatePost(
            postId,
            (p) => p.copyWith(liked: result.liked, likeCount: result.likeCount),
          );
          return;
        }
      }
    } on ApiException {
      if (!mounted) return;
      // Put back what the server still has.
      final want = _likeWanted[postId]!;
      _updatePost(
        postId,
        (p) => p.copyWith(
          liked: !want,
          likeCount: (p.likeCount + (want ? -1 : 1)).clamp(0, 1 << 31),
        ),
      );
    } finally {
      _likeInFlight.remove(postId);
      _likeWanted.remove(postId);
    }
  }

  // --- follow ----------------------------------------------------------------

  final _followInFlight = <int>{};

  /// Follow / unfollow the post's author through the existing listener follow
  /// API. Applied to every post by that author at once; reverted (and the
  /// error rethrown for the screen to show) if the server refuses.
  Future<void> toggleFollow(int postId) async {
    final post = postById(postId);
    final listeners = this.listeners;
    if (post == null || listeners == null || !post.author.canFollow) return;
    final authorId = post.author.id;
    if (_followInFlight.contains(authorId)) return;
    final want = !post.author.isFollowing;

    void apply(bool following) {
      final pinned = state.pinned;
      Post set(Post p) => p.author.id == authorId
          ? p.copyWith(author: p.author.copyWith(isFollowing: following))
          : p;
      state = state.copyWith(
        posts: [for (final p in state.posts) set(p)],
        pinned: pinned == null ? null : set(pinned),
      );
    }

    apply(want);
    _followInFlight.add(authorId);
    try {
      final result = await listeners.setRelation(
        listenerId: authorId,
        kind: 'follow',
        active: want,
      );
      if (mounted) apply(result.active);
    } on ApiException {
      if (mounted) apply(!want);
      rethrow;
    } finally {
      _followInFlight.remove(authorId);
    }
  }

  // --- comments and shares ---------------------------------------------------

  /// The server's comment total after the comments sheet added or deleted one.
  void setCommentCount(int postId, int count) =>
      _updatePost(postId, (p) => p.copyWith(commentCount: count));

  /// Records a share the user actually made (a completed share sheet or a
  /// copied link) and adopts the server's count. Best-effort: a failure here
  /// never undoes the share itself.
  Future<void> recordShare(int postId, {required String method}) async {
    try {
      final count = await _api.recordShare(postId, method: method);
      if (mounted) _updatePost(postId, (p) => p.copyWith(shareCount: count));
    } on ApiException {
      // The link was shared; only the counter missed it.
    }
  }
}

final feedControllerProvider = StateNotifierProvider<FeedController, FeedState>(
  (ref) => FeedController(
    ref.watch(feedApiProvider),
    listeners: ref.watch(listenersApiProvider),
  ),
);
