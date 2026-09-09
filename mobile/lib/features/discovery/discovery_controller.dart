import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/listeners_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/listener.dart';

/// Which rate the Audio/Video toggle displays.
///
/// This is a DISPLAY switch, not a filter. The backend exposes no per-listener
/// capability flag — every listener carries both an audioRate and a videoRate —
/// so filtering discovery by call type is not something the API can honour.
/// Rather than fake it, the toggle changes which rate each card shows.
enum CallMode { audio, video }

class DiscoveryState {
  const DiscoveryState({
    this.listeners = const [],
    this.filters = const DiscoveryFilters(),
    this.mode = CallMode.audio,
    this.searchQuery = '',
    this.isLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.nextOffset,
  });

  final List<ListenerSummary> listeners;
  final DiscoveryFilters filters;
  final CallMode mode;
  final String searchQuery;
  final bool isLoading;
  final bool isLoadingMore;
  final ApiException? error;
  final int? nextOffset;

  bool get hasMore => nextOffset != null;
  bool get isEmpty => !isLoading && error == null && visibleListeners.isEmpty;

  /// Search is applied CLIENT-SIDE, over the loaded page only.
  ///
  /// `GET /api/listeners` has no search parameter, so this cannot be a real
  /// server-side search and is not presented as one — see the API gaps table in
  /// mobile/README.md. It filters what is already on screen and nothing more.
  List<ListenerSummary> get visibleListeners {
    if (searchQuery.trim().isEmpty) return listeners;
    final q = searchQuery.trim().toLowerCase();
    return listeners
        .where(
          (l) =>
              l.name.toLowerCase().contains(q) ||
              (l.bio ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  DiscoveryState copyWith({
    List<ListenerSummary>? listeners,
    DiscoveryFilters? filters,
    CallMode? mode,
    String? searchQuery,
    bool? isLoading,
    bool? isLoadingMore,
    ApiException? error,
    int? nextOffset,
    bool clearError = false,
  }) {
    return DiscoveryState(
      listeners: listeners ?? this.listeners,
      filters: filters ?? this.filters,
      mode: mode ?? this.mode,
      searchQuery: searchQuery ?? this.searchQuery,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
      nextOffset: nextOffset,
    );
  }
}

class DiscoveryController extends StateNotifier<DiscoveryState> {
  DiscoveryController(this._api) : super(const DiscoveryState()) {
    load();
  }

  final ListenersApi _api;

  Future<void> load({bool refresh = false}) async {
    state = state.copyWith(
      isLoading: !refresh || state.listeners.isEmpty,
      clearError: true,
    );

    try {
      final page = await _api.discover(filters: state.filters, offset: 0);
      state = state.copyWith(
        listeners: page.listeners,
        nextOffset: page.nextOffset,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  /// Appends the next page. Guarded so a fast scroll cannot fire twice.
  Future<void> loadMore() async {
    final offset = state.nextOffset;
    if (offset == null || state.isLoadingMore || state.isLoading) return;

    state = state.copyWith(isLoadingMore: true);
    try {
      final page = await _api.discover(filters: state.filters, offset: offset);
      state = state.copyWith(
        listeners: [...state.listeners, ...page.listeners],
        nextOffset: page.nextOffset,
        isLoadingMore: false,
      );
    } on ApiException {
      // A failed page-append leaves what is already on screen intact; the user
      // can scroll again to retry.
      state = state.copyWith(isLoadingMore: false);
    }
  }

  Future<void> refresh() => load(refresh: true);

  /// Filter changes always reload from offset 0 — keeping the old list would
  /// mix results from two different queries.
  Future<void> setFilters(DiscoveryFilters filters) async {
    if (filters == state.filters) return;
    state = state.copyWith(filters: filters, listeners: []);
    await load();
  }

  void setMode(CallMode mode) => state = state.copyWith(mode: mode);
  void setSearchQuery(String query) =>
      state = state.copyWith(searchQuery: query);
}

final discoveryControllerProvider =
    StateNotifierProvider<DiscoveryController, DiscoveryState>(
      (ref) => DiscoveryController(ref.watch(listenersApiProvider)),
    );
