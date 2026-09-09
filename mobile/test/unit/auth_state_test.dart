import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/auth/auth_state.dart';
import 'package:moco/shared/models/user.dart';

MocoUser _user({String? displayName}) =>
    MocoUser(id: 1, phone: '+919876543210', displayName: displayName);

void main() {
  group('profile completion', () {
    test('a user without a display name must complete setup', () {
      expect(_user().isProfileComplete, isFalse);
      expect(AuthState.statusForUser(_user()), AuthStatus.awaitingProfile);
    });

    test('a whitespace-only name does not count as complete', () {
      // Otherwise a user could skip setup by submitting spaces.
      expect(_user(displayName: '   ').isProfileComplete, isFalse);
      expect(
        AuthState.statusForUser(_user(displayName: '   ')),
        AuthStatus.awaitingProfile,
      );
    });

    test('a real name completes the profile', () {
      expect(_user(displayName: 'Rahul').isProfileComplete, isTrue);
      expect(
        AuthState.statusForUser(_user(displayName: 'Rahul')),
        AuthStatus.authenticated,
      );
    });
  });

  group('AuthState transitions', () {
    test('starts initializing and is not signed in', () {
      const state = AuthState();
      expect(state.status, AuthStatus.initializing);
      expect(state.isInitializing, isTrue);
      expect(state.isSignedIn, isFalse);
    });

    test('awaitingProfile still counts as signed in', () {
      // The session is valid; only the profile is incomplete. Treating this as
      // signed out would send the user back through OTP.
      const state = AuthState(status: AuthStatus.awaitingProfile);
      expect(state.isSignedIn, isTrue);
    });

    test('unauthenticated is not signed in', () {
      const state = AuthState(status: AuthStatus.unauthenticated);
      expect(state.isSignedIn, isFalse);
    });

    test('clearUser drops the user while keeping onboarding', () {
      final state = AuthState(
        status: AuthStatus.authenticated,
        user: _user(displayName: 'Rahul'),
        onboardingComplete: true,
      );

      final signedOut = state.copyWith(
        status: AuthStatus.unauthenticated,
        clearUser: true,
      );

      expect(signedOut.user, isNull);
      // Signing out must not make the user watch onboarding again.
      expect(signedOut.onboardingComplete, isTrue);
    });
  });

  group('listener capability', () {
    test('kyc status drives what a listener may do', () {
      const approved = ListenerState(kycStatus: 'approved');
      const pending = ListenerState(kycStatus: 'pending');
      const rejected = ListenerState(kycStatus: 'rejected');

      expect(approved.isApproved, isTrue);
      expect(pending.isAwaitingReview, isTrue);
      expect(pending.isApproved, isFalse);
      expect(rejected.wasRejected, isTrue);
      expect(rejected.isApproved, isFalse);
    });

    test('role determines listener capability', () {
      expect(_user().canBeListener, isFalse);
      expect(MocoUser(id: 1, phone: '+91', role: 'both').canBeListener, isTrue);
      expect(
        MocoUser(id: 1, phone: '+91', role: 'listener').canBeListener,
        isTrue,
      );
    });
  });
}
