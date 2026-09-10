import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Owns the favourite/follow buttons for one listener.
///
/// Updates are optimistic — the button flips immediately — but every failure
/// rolls the state back to what it was. Nothing is persisted locally: the
/// server is the only record, so a rollback genuinely means "this did not
/// happen" rather than leaving the client quietly out of sync.
class ListenerRelationsController extends StateNotifier<ListenerDetail> {
  ListenerRelationsController(this._api, super.listener);

  final ListenersApi _api;

  /// In-flight kinds, so a double tap cannot fire two conflicting writes.
  final Set<String> _pending = {};

  bool isPending(String kind) => _pending.contains(kind);

  Future<ApiException?> toggleFavorite() => _toggle(
    kind: 'favorite',
    current: state.isFavorited,
    apply: (active) => state.copyWith(isFavorited: active),
  );

  Future<ApiException?> toggleFollow() => _toggle(
    kind: 'follow',
    current: state.isFollowing,
    apply: (active) => state.copyWith(
      isFollowing: active,
      // Keep the visible count honest while the request is in flight.
      followerCount: active
          ? state.followerCount + 1
          : (state.followerCount - 1).clamp(0, 1 << 30),
    ),
  );

  /// Returns null on success, or the failure so the screen can surface it.
  Future<ApiException?> _toggle({
    required String kind,
    required bool current,
    required ListenerDetail Function(bool active) apply,
  }) async {
    if (_pending.contains(kind)) return null;

    final previous = state;
    final next = !current;

    _pending.add(kind);
    state = apply(next);

    try {
      final result = await _api.setRelation(
        listenerId: state.id,
        kind: kind,
        active: next,
      );
      // Reconcile with the server's count rather than trusting the guess.
      state = state.copyWith(followerCount: result.followerCount);
      return null;
    } on ApiException catch (e) {
      // Roll back completely: an optimistic update that silently stuck would
      // show a follow that does not exist.
      state = previous;
      return e;
    } finally {
      _pending.remove(kind);
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
        listener,
      ),
    );
