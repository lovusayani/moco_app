import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/friends_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';

class FriendRequestsState {
  const FriendRequestsState({
    this.requests = const [],
    this.isLoading = true,
    this.error,
    this.busyIds = const {},
  });

  final List<PendingFriendRequest> requests;
  final bool isLoading;
  final ApiException? error;

  /// Request ids with an accept/reject call in flight.
  final Set<int> busyIds;

  bool get isEmpty => !isLoading && error == null && requests.isEmpty;
  bool get isFatalError => error != null && requests.isEmpty;

  FriendRequestsState copyWith({
    List<PendingFriendRequest>? requests,
    bool? isLoading,
    ApiException? error,
    Set<int>? busyIds,
    bool clearError = false,
  }) {
    return FriendRequestsState(
      requests: requests ?? this.requests,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      busyIds: busyIds ?? this.busyIds,
    );
  }
}

enum RespondOutcomeKind { accepted, declined, gone, failed, ignored }

class RespondOutcome {
  const RespondOutcome(this.kind, this.message);

  final RespondOutcomeKind kind;
  final String message;
}

/// Pending friend requests the signed-in user has received, with
/// accept/reject per row.
class FriendRequestsController extends StateNotifier<FriendRequestsState> {
  FriendRequestsController(this._api) : super(const FriendRequestsState()) {
    load();
  }

  final FriendsApi _api;
  bool _loading = false;

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final requests = await _api.pendingRequests();
      if (!mounted) return;
      state = state.copyWith(requests: requests, isLoading: false);
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(error: e, isLoading: false);
    } finally {
      _loading = false;
    }
  }

  Future<RespondOutcome> respond(int requestId, {required bool accept}) async {
    const ignored = RespondOutcome(RespondOutcomeKind.ignored, '');
    if (state.busyIds.contains(requestId)) return ignored;
    final matches = state.requests.where((r) => r.requestId == requestId);
    if (matches.isEmpty) return ignored;
    final request = matches.first;

    state = state.copyWith(busyIds: {...state.busyIds, requestId});
    try {
      await _api.respond(requestId, accept: accept);
      final outcome = accept
          ? RespondOutcome(
              RespondOutcomeKind.accepted,
              'You and ${request.requesterName} are now friends',
            )
          : const RespondOutcome(RespondOutcomeKind.declined, 'Request declined');
      if (!mounted) return outcome;
      _removeRow(requestId);
      return outcome;
    } on ApiException catch (e) {
      final gone = e.code == 'already_responded' ||
          e.kind == ApiErrorKind.notFound ||
          e.kind == ApiErrorKind.forbidden;
      if (gone) {
        final outcome = RespondOutcome(
          RespondOutcomeKind.gone,
          e.kind == ApiErrorKind.forbidden
              ? e.message
              : 'This request is no longer pending',
        );
        if (!mounted) return outcome;
        _removeRow(requestId);
        return outcome;
      }
      final outcome = RespondOutcome(RespondOutcomeKind.failed, e.message);
      if (!mounted) return outcome;
      state = state.copyWith(busyIds: {...state.busyIds}..remove(requestId));
      return outcome;
    }
  }

  void _removeRow(int requestId) {
    state = state.copyWith(
      requests: state.requests.where((r) => r.requestId != requestId).toList(),
      busyIds: {...state.busyIds}..remove(requestId),
    );
  }
}

final friendRequestsControllerProvider =
    StateNotifierProvider.autoDispose<FriendRequestsController, FriendRequestsState>(
      (ref) => FriendRequestsController(ref.watch(friendsApiProvider)),
    );
