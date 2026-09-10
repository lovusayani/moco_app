import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/listeners_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/realtime/socket_service.dart';
import '../../shared/models/listener.dart';
import '../../core/utils/ws_events.dart';

/// Which call type the Callers/Video toggle is showing.
///
/// This is a real filter: it goes to the server as `callType`, which returns
/// only listeners who accept that kind of call. It also selects which rate the
/// cards display.
enum CallMode { audio, video }

class DiscoveryState {
  const DiscoveryState({
    this.listeners = const [],
    this.filters = const DiscoveryFilters(),
    this.mode = CallMode.audio,
    this.isLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.nextOffset,
  });

  final List<ListenerSummary> listeners;
  final DiscoveryFilters filters;
  final CallMode mode;
  final bool isLoading;
  final bool isLoadingMore;
  final ApiException? error;
  final int? nextOffset;

  bool get hasMore => nextOffset != null;
  bool get isEmpty => !isLoading && error == null && listeners.isEmpty;

  /// Whether the empty state should blame a search rather than filters.
  bool get isEmptyFromSearch => isEmpty && filters.hasQuery;

  String get searchQuery => filters.query ?? '';

  DiscoveryState copyWith({
    List<ListenerSummary>? listeners,
    DiscoveryFilters? filters,
    CallMode? mode,
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
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
      nextOffset: nextOffset,
    );
  }
}

class DiscoveryController extends StateNotifier<DiscoveryState> {
  DiscoveryController(this._api, this._socket) : super(const DiscoveryState()) {
    _subscribeToPresence();
    load();
  }

  final ListenersApi _api;

  /// Nullable so tests can construct the controller without a socket.
  final SocketService? _socket;

  Timer? _searchDebounce;
  VoidCallback? _presenceOff;

  /// Guards against an older, slower request overwriting a newer one — typing
  /// quickly can otherwise land results out of order.
  int _requestId = 0;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _presenceOff?.call();
    super.dispose();
  }

  /// Subscribes to the server's presence broadcast.
  void _subscribeToPresence() {
    _presenceOff = _socket?.on(WsEvents.presence, (data) {
      if (data is! Map) return;
      final id = (data['listenerId'] as num?)?.toInt();
      if (id == null) return;

      applyPresence(
        listenerId: id,
        isOnline: data['isOnline'] as bool? ?? false,
        isBusy: data['isBusy'] as bool? ?? false,
      );
    });
  }

  /// Applies a presence change to the loaded grid.
  ///
  /// Public because presence is a domain operation, not a socket detail — the
  /// socket is just one way it arrives. A listener not currently on screen is
  /// ignored rather than appended: they may not match the active filters.
  void applyPresence({
    required int listenerId,
    required bool isOnline,
    required bool isBusy,
  }) {
    final index = state.listeners.indexWhere((l) => l.id == listenerId);
    if (index < 0) return;

    final updated = [...state.listeners];
    updated[index] = updated[index].withPresence(
      isOnline: isOnline,
      isBusy: isBusy,
    );
    state = state.copyWith(listeners: updated);
  }

  Future<void> load({bool refresh = false}) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      isLoading: !refresh || state.listeners.isEmpty,
      clearError: true,
    );

    try {
      final page = await _api.discover(filters: state.filters, offset: 0);
      if (requestId != _requestId) return; // superseded
      state = state.copyWith(
        listeners: page.listeners,
        nextOffset: page.nextOffset,
        isLoading: false,
      );
    } on ApiException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  /// Appends the next page. Guarded so a fast scroll cannot fire twice.
  Future<void> loadMore() async {
    final offset = state.nextOffset;
    if (offset == null || state.isLoadingMore || state.isLoading) return;

    final requestId = _requestId;
    state = state.copyWith(isLoadingMore: true);

    try {
      final page = await _api.discover(filters: state.filters, offset: offset);
      // A filter or search change since this started invalidates the append.
      if (requestId != _requestId) return;
      state = state.copyWith(
        listeners: [...state.listeners, ...page.listeners],
        nextOffset: page.nextOffset,
        isLoadingMore: false,
      );
    } on ApiException {
      // A failed append leaves what is on screen intact; scrolling retries.
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

  /// The toggle is a real server-side filter, so changing it refetches.
  Future<void> setMode(CallMode mode) async {
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode, listeners: []);
    await setFilters(
      state.filters.copyWith(
        callType: mode == CallMode.video ? 'video' : 'audio',
      ),
    );
  }

  /// Debounced so typing does not fire a request per keystroke.
  void setSearchQuery(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      final trimmed = query.trim();
      setFilters(
        trimmed.isEmpty
            ? state.filters.copyWith(clearQuery: true)
            : state.filters.copyWith(query: trimmed),
      );
    });
  }

  /// Applies a search immediately, for submit-on-keyboard.
  Future<void> submitSearch(String query) async {
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    await setFilters(
      trimmed.isEmpty
          ? state.filters.copyWith(clearQuery: true)
          : state.filters.copyWith(query: trimmed),
    );
  }
}

final discoveryControllerProvider =
    StateNotifierProvider<DiscoveryController, DiscoveryState>(
      (ref) => DiscoveryController(
        ref.watch(listenersApiProvider),
        ref.watch(socketServiceProvider),
      ),
    );
