import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/live_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/live.dart';

/// The admin's Live settings, fetched when the Live screen opens. Scoped to
/// the screen (autoDispose) so a Live failure never touches the rest of the
/// app, and re-entering Live picks up newly saved settings.
final liveConfigProvider = FutureProvider.autoDispose<LiveConfig>(
  (ref) => ref.watch(liveApiProvider).config(),
);

/// Whether this device already confirmed the 18+ gate (local preference).
final liveAgeConfirmedProvider = StateProvider<bool>(
  (ref) => ref.watch(appPreferencesProvider).liveAgeConfirmed,
);

class LiveModelsState {
  const LiveModelsState({
    this.models = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.available = true,
    this.error,
    this.loadMoreError,
  });

  final List<LiveModel> models;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  /// False when the backend says Live has no provider right now.
  final bool available;
  final ApiException? error;
  final ApiException? loadMoreError;

  bool get isEmpty =>
      !isLoading && error == null && available && models.isEmpty;

  LiveModelsState copyWith({
    List<LiveModel>? models,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    bool? available,
    ApiException? error,
    bool clearError = false,
    ApiException? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return LiveModelsState(
      models: models ?? this.models,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      available: available ?? this.available,
      error: clearError ? null : (error ?? this.error),
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

/// Pages through `GET /live/models` with the admin's page size. Order and
/// visibility are the backend's; this only appends pages, dropping any
/// model already shown (the online list can shift between pages).
class LiveModelsController extends StateNotifier<LiveModelsState> {
  LiveModelsController(this._api, this.pageSize)
    : super(const LiveModelsState());

  final LiveApi _api;
  final int pageSize;

  Future<void> load() async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearLoadMoreError: true,
    );
    try {
      final page = await _api.models(limit: pageSize);
      if (!mounted) return;
      state = LiveModelsState(
        models: page.models,
        available: page.available,
        hasMore: page.available && page.models.length >= pageSize,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() => load();

  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    state = state.copyWith(isLoadingMore: true, clearLoadMoreError: true);
    try {
      final page = await _api.models(
        limit: pageSize,
        offset: state.models.length,
      );
      if (!mounted) return;
      final seen = {for (final m in state.models) m.username};
      final fresh = page.models.where((m) => seen.add(m.username)).toList();
      state = state.copyWith(
        models: [...state.models, ...fresh],
        isLoadingMore: false,
        hasMore: page.models.length >= pageSize && fresh.isNotEmpty,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoadingMore: false, loadMoreError: e);
    }
  }
}

/// One controller per page size; created only after the config (and the age
/// gate) allow models to load.
final liveModelsControllerProvider = StateNotifierProvider.autoDispose
    .family<LiveModelsController, LiveModelsState, int>(
      (ref, pageSize) =>
          LiveModelsController(ref.watch(liveApiProvider), pageSize)..load(),
    );

/// The model a player screen was opened for, kept so a reload of
/// `/live/watch/:username` can still show its details while in this session.
final liveSelectedModelProvider = StateProvider<LiveModel?>((ref) => null);
