import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/features/profile_setup/profile_setup_screen.dart';
import 'package:moco/shared/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

class _MockUsersApi extends Mock implements UsersApi {}

class _MockAuthApi extends Mock implements AuthApi {}

class _FakeStore implements SecureStore {
  String? token = 'jwt';
  @override
  Future<void> clear() async => token = null;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String value) async => token = value;
}

void main() {
  late _MockUsersApi usersApi;
  late AppPreferences prefs;

  setUp(() async {
    usersApi = _MockUsersApi();
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.create();
  });

  Widget subject() => wrapWidget(
    const ProfileSetupScreen(),
    overrides: [
      appPreferencesProvider.overrideWithValue(prefs),
      secureStoreProvider.overrideWithValue(_FakeStore()),
      usersApiProvider.overrideWithValue(usersApi),
      authApiProvider.overrideWithValue(_MockAuthApi()),
    ],
  );

  testWidgets('an empty name is rejected before any request', (tester) async {
    await tester.pumpWidget(subject());

    await tester.tap(find.byKey(const Key('profile_save')));
    await tester.pump();

    expect(find.text('Please enter your name'), findsOneWidget);
    verifyNever(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    );
  });

  testWidgets('a one-character name is rejected, matching the backend rule', (
    tester,
  ) async {
    await tester.pumpWidget(subject());

    await tester.enterText(find.byKey(const Key('profile_name_field')), 'R');
    await tester.tap(find.byKey(const Key('profile_save')));
    await tester.pump();

    expect(find.textContaining('at least 2 characters'), findsOneWidget);
  });

  testWidgets('a valid name is saved', (tester) async {
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenAnswer(
      (_) async =>
          const MocoUser(id: 1, phone: '+919876543210', displayName: 'Rahul'),
    );

    await tester.pumpWidget(subject());
    await tester.enterText(
      find.byKey(const Key('profile_name_field')),
      'Rahul',
    );
    await tester.tap(find.byKey(const Key('profile_save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    verify(
      () => usersApi.updateProfile(
        displayName: 'Rahul',
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).called(1);
  });

  testWidgets('the listener application is collapsed and optional', (
    tester,
  ) async {
    await tester.pumpWidget(subject());

    final toggle = tester.widget<Switch>(
      find.byKey(const Key('profile_listener_toggle')),
    );
    // A normal user must never be forced through listener fields.
    expect(toggle.value, isFalse);
    expect(find.textContaining('identity verification'), findsNothing);
  });

  testWidgets('enabling the toggle reveals what applying means', (
    tester,
  ) async {
    await tester.pumpWidget(subject());

    await tester.tap(find.byKey(const Key('profile_listener_toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('identity verification'), findsOneWidget);
  });

  testWidgets('applying as a listener calls become-listener', (tester) async {
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenAnswer(
      (_) async =>
          const MocoUser(id: 1, phone: '+919876543210', displayName: 'Priya'),
    );
    when(() => usersApi.becomeListener())
        .thenAnswer((_) async => {'role': 'both', 'kycStatus': 'unsubmitted'});
    when(() => usersApi.me()).thenAnswer(
      (_) async => const MocoUser(
        id: 1,
        phone: '+919876543210',
        displayName: 'Priya',
        role: 'both',
      ),
    );

    await tester.pumpWidget(subject());
    await tester.enterText(
      find.byKey(const Key('profile_name_field')),
      'Priya',
    );
    await tester.tap(find.byKey(const Key('profile_listener_toggle')));
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('profile_save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    verify(() => usersApi.becomeListener()).called(1);
  });

  testWidgets('a server validation error is shown against the field', (
    tester,
  ) async {
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        message: 'Invalid request',
        fieldErrors: {'displayName': 'That name is not allowed'},
      ),
    );

    await tester.pumpWidget(subject());
    await tester.enterText(
      find.byKey(const Key('profile_name_field')),
      'Rahul',
    );
    await tester.tap(find.byKey(const Key('profile_save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('That name is not allowed'), findsOneWidget);
  });
}
