import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/feed_api.dart';
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
  });

  /// Newest first, exactly as the server ordered them.
  final List<Post> posts;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final ApiException? error;

  bool get isEmpty => !isLoading && error == null && posts.isEmpty;

  /// An error with nothing to show is a full-screen retry; an error with posts
  /// already on screen must not blank the feed the user is looking at.
  bool get isFatalError => error != null && posts.isEmpty;

  FeedState copyWith({
    List<Post>? posts,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    ApiException? error,
    bool clearError = false,
  }) {
    return FeedState(
      posts: posts ?? this.posts,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the feed list and its pagination cursor.
///
/// The feed needs no realtime: a post is not time-critical the way a call or a
/// message is, so there is no socket subscription here and no second
/// connection. Pull-to-refresh and pagination are the whole update model.
class FeedController extends StateNotifier<FeedState> {
  FeedController(this._api) : super(const FeedState()) {
    load();
  }

  final FeedApi _api;

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
    final merged = byId.values.toList()
      ..sort((a, b) => b.id.compareTo(a.id));
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
    );
  }
}

final feedControllerProvider = StateNotifierProvider<FeedController, FeedState>(
  (ref) => FeedController(ref.watch(feedApiProvider)),
);
