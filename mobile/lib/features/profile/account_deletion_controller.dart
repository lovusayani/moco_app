import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/users_api.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';

enum DeletionStatus { idle, deleting, done }

class AccountDeletionState {
  const AccountDeletionState({this.status = DeletionStatus.idle, this.error});

  final DeletionStatus status;
  final ApiException? error;

  bool get isBusy => status == DeletionStatus.deleting;

  AccountDeletionState copyWith({DeletionStatus? status, ApiException? error, bool clearError = false}) {
    return AccountDeletionState(
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Deletes the signed-in account. High-risk by design, so this does exactly
/// two things and nothing else: call the backend (which is the only thing
/// that ever touches the row — there is no client-side SQL), then clear local
/// session state so the app returns to onboarding/login the same way any
/// other sign-out does. Routing reacts to that state change; this controller
/// never navigates directly.
class AccountDeletionController extends StateNotifier<AccountDeletionState> {
  AccountDeletionController(this._usersApi, this._authController)
    : super(const AccountDeletionState());

  final UsersApi _usersApi;
  final AuthController _authController;

  Future<bool> confirmDeletion() async {
    if (state.isBusy) return false;
    state = state.copyWith(status: DeletionStatus.deleting, clearError: true);
    try {
      await _usersApi.deleteAccount();
      // The backend has no session to hand back after a delete — clear the
      // local token ourselves, exactly as a normal sign-out does.
      await _authController.signOut();
      if (mounted) state = state.copyWith(status: DeletionStatus.done);
      return true;
    } on ApiException catch (e) {
      if (mounted) state = state.copyWith(status: DeletionStatus.idle, error: e);
      return false;
    }
  }
}

final accountDeletionControllerProvider = StateNotifierProvider.autoDispose<
  AccountDeletionController,
  AccountDeletionState
>((ref) {
  return AccountDeletionController(
    ref.watch(usersApiProvider),
    ref.watch(authActionsProvider),
  );
});
