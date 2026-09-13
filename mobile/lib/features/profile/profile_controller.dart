import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/listeners_api.dart';
import '../../core/api/payouts_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/storage/secure_store.dart';
import '../../shared/models/earnings.dart';

/// Which side of the account the Profile screen is currently showing.
///
/// This is display state only — the backend has no "active mode" concept. A
/// `both`-role account can do both at once; switching sides never calls the
/// server and never changes what the account can do. It only changes which
/// sections of the Profile screen render, exactly as the design calls for one
/// account and one shell.
class ActiveRoleController extends StateNotifier<String> {
  ActiveRoleController(this._prefs) : super(_prefs.activeRole);

  final AppPreferences _prefs;

  static const caller = 'caller';
  static const listener = 'listener';

  Future<void> setRole(String role) async {
    if (role == state) return;
    state = role;
    await _prefs.setActiveRole(role);
  }
}

final activeRoleProvider = StateNotifierProvider<ActiveRoleController, String>(
  (ref) => ActiveRoleController(ref.watch(appPreferencesProvider)),
);

class ProfileState {
  const ProfileState({
    this.isTogglingAvailability = false,
    this.availabilityError,
    this.earnings,
    this.isLoadingEarnings = false,
    this.earningsError,
  });

  final bool isTogglingAvailability;
  final ApiException? availabilityError;
  final EarningsSummary? earnings;
  final bool isLoadingEarnings;
  final ApiException? earningsError;

  ProfileState copyWith({
    bool? isTogglingAvailability,
    ApiException? availabilityError,
    EarningsSummary? earnings,
    bool? isLoadingEarnings,
    ApiException? earningsError,
    bool clearAvailabilityError = false,
    bool clearEarningsError = false,
  }) {
    return ProfileState(
      isTogglingAvailability: isTogglingAvailability ?? this.isTogglingAvailability,
      availabilityError:
          clearAvailabilityError ? null : (availabilityError ?? this.availabilityError),
      earnings: earnings ?? this.earnings,
      isLoadingEarnings: isLoadingEarnings ?? this.isLoadingEarnings,
      earningsError: clearEarningsError ? null : (earningsError ?? this.earningsError),
    );
  }
}

/// Owns the two listener-only actions on the Profile screen: the
/// online/offline toggle and the earnings summary. Everything else on the
/// screen (name, avatar, role, KYC status) reads straight from
/// [authControllerProvider], which is already the single source of truth for
/// the signed-in user — this controller does not duplicate it.
class ProfileController extends StateNotifier<ProfileState> {
  ProfileController(this._listenersApi, this._payoutsApi, this._refreshUser)
    : super(const ProfileState());

  final ListenersApi _listenersApi;
  final PayoutsApi _payoutsApi;
  final Future<void> Function() _refreshUser;

  /// Toggles online/offline. The backend remains authoritative — going online
  /// before KYC approval is refused server-side, and this surfaces that
  /// refusal rather than flipping the switch anyway. On success it re-reads
  /// `/users/me` so the switch reflects the server's answer, not an optimistic
  /// guess (mirrors the pattern WalletController uses after a purchase).
  Future<void> setAvailability(bool isOnline) async {
    if (state.isTogglingAvailability) return;
    state = state.copyWith(isTogglingAvailability: true, clearAvailabilityError: true);
    try {
      await _listenersApi.setOnline(isOnline);
      await _refreshUser();
      state = state.copyWith(isTogglingAvailability: false);
    } on ApiException catch (e) {
      state = state.copyWith(isTogglingAvailability: false, availabilityError: e);
    }
  }

  Future<void> loadEarnings() async {
    state = state.copyWith(isLoadingEarnings: true, clearEarningsError: true);
    try {
      final earnings = await _payoutsApi.earnings();
      state = state.copyWith(earnings: earnings, isLoadingEarnings: false);
    } on ApiException catch (e) {
      state = state.copyWith(isLoadingEarnings: false, earningsError: e);
    }
  }
}

final profileControllerProvider =
    StateNotifierProvider<ProfileController, ProfileState>((ref) {
      return ProfileController(
        ref.watch(listenersApiProvider),
        ref.watch(payoutsApiProvider),
        () => ref.read(authActionsProvider).refreshUser(),
      );
    });
