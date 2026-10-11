import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/friends_api.dart';
import '../../core/api/listeners_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/listener.dart';

/// Loads one listener profile, including the viewer's own relation state.
final listenerProfileProvider = FutureProvider.family<ListenerDetail, int>((
  ref,
  id,
) {
  return ref.watch(listenersApiProvider).byId(id);
});

/// "Similar listeners" for the horizontal scroller.
///
/// The backend has no similarity endpoint, so this is an explicit CLIENT-SIDE
/// heuristic over the real discovery endpoint: listeners sharing the profile's
/// primary language, with the profile itself removed.
final similarListenersProvider =
    FutureProvider.family<List<ListenerSummary>, ListenerDetail>((
      ref,
      listener,
    ) async {
      final api = ref.watch(listenersApiProvider);
      final language = listener.languages.isNotEmpty
          ? listener.languages.first
          : null;

      final page = await api.discover(
        filters: DiscoveryFilters(language: language),
        limit: 10,
      );

      return page.listeners.where((l) => l.id != listener.id).take(8).toList();
    });

/// Owns the favourite/follow and friend-request buttons for one listener.
///
/// Heart (favorite) now drives BOTH 'favorite' and 'follow' relations, so it
/// controls the follower count. The person+ button sends a friend request
/// instead of toggling follow.
class ListenerRelationsController extends StateNotifier<ListenerDetail> {
  ListenerRelationsController(this._api, this._friendsApi, super.listener);

  final ListenersApi _api;
  final FriendsApi _friendsApi;

  final Set<String> _pending = {};

  bool isPending(String kind) => _pending.contains(kind);

  /// Heart button: toggles both 'favorite' and 'follow' at once.
  Future<ApiException?> toggleFavorite() async {
    if (_pending.contains('favorite')) return null;

    final previous = state;
    final next = !state.isFavorited;

    _pending.add('favorite');
    state = state.copyWith(
      isFavorited: next,
      isFollowing: next,
      followerCount: next
          ? state.followerCount + 1
          : (state.followerCount - 1).clamp(0, 1 << 30),
    );

    try {
      // Fire both relation writes in parallel
      final results = await Future.wait([
        _api.setRelation(listenerId: state.id, kind: 'favorite', active: next),
        _api.setRelation(listenerId: state.id, kind: 'follow', active: next),
      ]);
      state = state.copyWith(followerCount: results[1].followerCount);
      return null;
    } on ApiException catch (e) {
      state = previous;
      return e;
    } finally {
      _pending.remove('favorite');
    }
  }

  /// Person+ button: sends a friend request. Does NOT change follower count.
  Future<ApiException?> sendFriendRequest() async {
    if (_pending.contains('friend')) return null;

    final previous = state;
    _pending.add('friend');
    state = state.copyWith(friendshipStatus: 'pending');

    try {
      await _friendsApi.sendRequest(state.id);
      return null;
    } on ApiException catch (e) {
      state = previous;
      // Cooldown after a rejection, or too many requests: one calm message.
      if (e.kind == ApiErrorKind.rateLimited) {
        return ApiException(
          kind: e.kind,
          code: e.code,
          statusCode: e.statusCode,
          message: 'You can send another request later.',
        );
      }
      return e;
    } finally {
      _pending.remove('friend');
    }
  }
}

final listenerRelationsProvider =
    StateNotifierProvider.family<
      ListenerRelationsController,
      ListenerDetail,
      ListenerDetail
    >(
      (ref, listener) => ListenerRelationsController(
        ref.watch(listenersApiProvider),
        ref.watch(friendsApiProvider),
        listener,
      ),
    );
