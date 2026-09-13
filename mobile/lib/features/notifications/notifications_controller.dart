import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/notifications_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/notification.dart';

class NotificationsState {
  const NotificationsState({
    this.notifications = const [],
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.unreadCount = 0,
    this.error,
  });

  final List<AppNotification> notifications;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final int unreadCount;
  final ApiException? error;

  bool get isEmpty => !isLoading && error == null && notifications.isEmpty;
  bool get isFatalError => error != null && notifications.isEmpty;

  NotificationsState copyWith({
    List<AppNotification>? notifications,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    int? unreadCount,
    ApiException? error,
    bool clearError = false,
  }) {
    return NotificationsState(
      notifications: notifications ?? this.notifications,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      unreadCount: unreadCount ?? this.unreadCount,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the notification inbox. No realtime here — a notification is a fact
/// worth checking when the user opens the inbox, not something that needs to
/// interrupt whatever else they are doing; the badge is refreshed on load.
class NotificationsController extends StateNotifier<NotificationsState> {
  NotificationsController(this._api) : super(const NotificationsState()) {
    load();
  }

  final NotificationsApi _api;
  int? _cursor;
  bool _loadingPage = false;

  Future<void> load() async {
    if (_loadingPage) return;
    _loadingPage = true;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final page = await _api.list();
      _cursor = page.nextCursor;
      state = state.copyWith(
        notifications: page.notifications,
        hasMore: page.hasMore,
        unreadCount: page.unreadCount,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(error: e, isLoading: false);
    } finally {
      _loadingPage = false;
    }
  }

  Future<void> loadMore() async {
    if (_loadingPage || !state.hasMore || state.isLoading) return;
    _loadingPage = true;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final page = await _api.list(before: _cursor);
      _cursor = page.nextCursor;
      final byId = {for (final n in state.notifications) n.id: n};
      for (final n in page.notifications) {
        byId[n.id] = n;
      }
      final merged = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));
      state = state.copyWith(notifications: merged, hasMore: page.hasMore, isLoadingMore: false);
    } on ApiException catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e);
    } finally {
      _loadingPage = false;
    }
  }

  /// Marks one read, optimistically — a failed mark-read is not worth
  /// surfacing an error for; the next load reconciles it.
  Future<void> markRead(int id) async {
    final index = state.notifications.indexWhere((n) => n.id == id);
    if (index < 0 || state.notifications[index].read) return;

    final updated = [...state.notifications];
    updated[index] = updated[index].markRead();
    state = state.copyWith(
      notifications: updated,
      unreadCount: (state.unreadCount - 1).clamp(0, 1 << 30),
    );

    try {
      await _api.markRead(id);
    } on ApiException {
      // Reconciled on next load(); an inbox is low-stakes enough not to retry.
    }
  }

  Future<void> markAllRead() async {
    if (state.unreadCount == 0) return;
    final updated = state.notifications.map((n) => n.markRead()).toList();
    state = state.copyWith(notifications: updated, unreadCount: 0);
    try {
      await _api.markAllRead();
    } on ApiException {
      // Same reconciliation story as markRead.
    }
  }

  /// Removes one notification immediately (swipe-to-delete), rolling back if
  /// the server call fails — unlike read state, a delete that silently failed
  /// would leave the user thinking it worked when it did not.
  Future<void> delete(int id) async {
    final removed = state.notifications.firstWhere((n) => n.id == id);
    final wasUnread = !removed.read;
    state = state.copyWith(
      notifications: state.notifications.where((n) => n.id != id).toList(),
      unreadCount: wasUnread ? (state.unreadCount - 1).clamp(0, 1 << 30) : state.unreadCount,
    );

    try {
      await _api.delete(id);
    } on ApiException catch (e) {
      final restored = [...state.notifications, removed]
        ..sort((a, b) => b.id.compareTo(a.id));
      state = state.copyWith(
        notifications: restored,
        unreadCount: wasUnread ? state.unreadCount + 1 : state.unreadCount,
        error: e,
      );
    }
  }
}

final notificationsControllerProvider =
    StateNotifierProvider<NotificationsController, NotificationsState>(
      (ref) => NotificationsController(ref.watch(notificationsApiProvider)),
    );
