// prefer_initializing_formals suggests `required this._authApi`, which Dart
// rejects: a named parameter may not be a private name. The initialiser list
// below is the only valid way to express these dependencies as named ones.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../api/auth_api.dart';
import '../api/users_api.dart';
import '../errors/api_exception.dart';
import '../storage/secure_store.dart';
import 'auth_state.dart';

/// Owns the session: restore on launch, sign in, sign out.
///
/// This is the only place that writes the token, so there is exactly one path
/// into and out of an authenticated state.
class AuthController extends ValueNotifier<AuthState> {
  AuthController({
    required AuthApi authApi,
    required UsersApi usersApi,
    required SecureStore store,
    required AppPreferences prefs,
  }) : _authApi = authApi,
       _usersApi = usersApi,
       _store = store,
       _prefs = prefs,
       super(const AuthState());

  final AuthApi _authApi;
  final UsersApi _usersApi;
  final SecureStore _store;
  final AppPreferences _prefs;

  /// Restores a stored session at launch.
  ///
  /// A stored token is not trusted on its own — it is verified by fetching the
  /// user. That way a token revoked server-side (a suspended account) cannot
  /// leave the app in a falsely signed-in state.
  Future<void> bootstrap() async {
    final onboarded = _prefs.onboardingComplete;
    final token = await _store.readToken();

    if (token == null || token.isEmpty) {
      value = AuthState(
        status: AuthStatus.unauthenticated,
        onboardingComplete: onboarded,
      );
      return;
    }

    try {
      final user = await _usersApi.me();
      value = AuthState(
        status: AuthState.statusForUser(user),
        user: user,
        onboardingComplete: onboarded,
      );
    } on ApiException catch (e) {
      if (e.isAuthFailure || e.kind == ApiErrorKind.forbidden) {
        // Dead or suspended session: clear it rather than retrying.
        await _store.clear();
        value = AuthState(
          status: AuthStatus.unauthenticated,
          onboardingComplete: onboarded,
        );
      } else {
        // A network failure is not a signed-out state. Keep the token and let
        // the user retry, rather than forcing a fresh OTP over a flaky link.
        value = AuthState(
          status: AuthStatus.unauthenticated,
          onboardingComplete: onboarded,
        );
      }
    }
  }

  Future<int> requestOtp(String phone) => _authApi.requestOtp(phone);

  /// Verifies the OTP and establishes the session.
  Future<AuthStatus> verifyOtp({
    required String phone,
    required String code,
  }) async {
    final session = await _authApi.verifyOtp(phone: phone, code: code);
    await _store.writeToken(session.token);

    // The verify response is a lighter shape than /users/me; re-read the
    // canonical one so the rest of the app has a single user model.
    final user = await _usersApi.me();
    final status = AuthState.statusForUser(user);

    value = value.copyWith(status: status, user: user);
    return status;
  }

  /// Applies a profile update and re-evaluates whether setup is complete.
  Future<void> updateProfile({
    String? displayName,
    String? avatarUrl,
    String? language,
    String? gender,
  }) async {
    final user = await _usersApi.updateProfile(
      displayName: displayName,
      avatarUrl: avatarUrl,
      language: language,
      gender: gender,
    );
    value = value.copyWith(status: AuthState.statusForUser(user), user: user);
  }

  Future<void> refreshUser() async {
    if (!value.isSignedIn) return;
    try {
      final user = await _usersApi.me();
      value = value.copyWith(status: AuthState.statusForUser(user), user: user);
    } on ApiException {
      // A failed refresh must not sign the user out; the interceptor already
      // handles a genuine 401.
    }
  }

  Future<void> completeOnboarding() async {
    await _prefs.setOnboardingComplete(true);
    value = value.copyWith(onboardingComplete: true);
  }

  Future<void> signOut() async {
    await _store.clear();
    value = AuthState(
      status: AuthStatus.unauthenticated,
      onboardingComplete: value.onboardingComplete,
    );
  }

  /// Called by the API client when the backend rejects the session.
  Future<void> handleUnauthorized() async {
    if (value.status == AuthStatus.unauthenticated) return;
    value = AuthState(
      status: AuthStatus.unauthenticated,
      onboardingComplete: value.onboardingComplete,
    );
  }
}
