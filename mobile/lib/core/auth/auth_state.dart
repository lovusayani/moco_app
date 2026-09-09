import '../../shared/models/user.dart';

/// Where the app is in its startup/auth lifecycle.
///
/// A single closed enum drives routing, which is what keeps the launch flow
/// deterministic and free of redirect flicker.
enum AuthStatus {
  /// Restoring a stored session. Routing waits here rather than guessing.
  initializing,

  /// No stored session.
  unauthenticated,

  /// Signed in, but no display name yet — profile setup is required.
  awaitingProfile,

  /// Signed in and ready for the app shell.
  authenticated,
}

class AuthState {
  const AuthState({
    this.status = AuthStatus.initializing,
    this.user,
    this.onboardingComplete = false,
  });

  final AuthStatus status;
  final MocoUser? user;
  final bool onboardingComplete;

  bool get isInitializing => status == AuthStatus.initializing;
  bool get isSignedIn =>
      status == AuthStatus.authenticated ||
      status == AuthStatus.awaitingProfile;

  /// Derives the status a signed-in user should be in.
  ///
  /// Profile completeness is decided in exactly one place so routing, the shell
  /// and the profile screen can never disagree about it.
  static AuthStatus statusForUser(MocoUser user) => user.isProfileComplete
      ? AuthStatus.authenticated
      : AuthStatus.awaitingProfile;

  AuthState copyWith({
    AuthStatus? status,
    MocoUser? user,
    bool? onboardingComplete,
    bool clearUser = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: clearUser ? null : (user ?? this.user),
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AuthState &&
      other.status == status &&
      other.user == user &&
      other.onboardingComplete == onboardingComplete;

  @override
  int get hashCode => Object.hash(status, user, onboardingComplete);
}
