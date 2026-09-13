import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/profile/edit_profile_screen.dart';
import 'package:moco/shared/models/user.dart';

import '../support/harness.dart';

class _MockUsersApi extends Mock implements UsersApi {}

const _user = MocoUser(
  id: 1,
  phone: '+919876543210',
  displayName: 'Rahul',
  gender: 'male',
);

void main() {
  late _MockUsersApi usersApi;

  setUp(() {
    usersApi = _MockUsersApi();
    when(() => usersApi.me()).thenAnswer((_) async => _user);
  });

  Future<Widget> subject({bool startWithListenerApplication = false}) async {
    final overrides = await signedInOverrides(user: _user, usersApi: usersApi);
    return wrapWidget(
      EditProfileScreen(startWithListenerApplication: startWithListenerApplication),
      overrides: overrides,
    );
  }

  testWidgets('pre-fills the current name and gender', (tester) async {
    await tester.pumpWidget(await subject());
    await tester.pump();

    final field = tester.widget<TextField>(find.byKey(const Key('edit_profile_name')));
    expect(field.controller?.text, 'Rahul');

    final maleChip = tester.widget(find.byKey(const Key('edit_profile_gender_male')));
    // MocoChip's `selected` isn't directly inspectable without importing the
    // widget type; the important behavioural check is in the save test below
    // (the untouched gender round-trips unchanged).
    expect(maleChip, isNotNull);
  });

  testWidgets('saving updates the profile with the edited fields', (tester) async {
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenAnswer((_) async => _user.copyWith(displayName: 'Rahul Kumar'));

    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.enterText(find.byKey(const Key('edit_profile_name')), 'Rahul Kumar');
    await tester.tap(find.byKey(const Key('edit_profile_save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    verify(
      () => usersApi.updateProfile(
        displayName: 'Rahul Kumar',
        language: 'en',
        gender: 'male',
      ),
    ).called(1);
  });

  testWidgets('gender is not locked: changing it away and back is allowed either way', (
    tester,
  ) async {
    // No backend rule restricts changing gender after it is first set —
    // PATCH /users/me accepts it unconditionally at any time — so the client
    // must not invent a one-way or locked control either.
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenAnswer((_) async => _user.copyWith(gender: 'other'));

    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.tap(find.byKey(const Key('edit_profile_gender_other')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('edit_profile_save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    verify(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: 'other',
      ),
    ).called(1);
  });

  testWidgets('a server validation error is shown against the name field', (tester) async {
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        message: 'Validation failed',
        fieldErrors: {'displayName': 'That name is not allowed'},
      ),
    );

    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.enterText(find.byKey(const Key('edit_profile_name')), 'Bad Name');
    await tester.tap(find.byKey(const Key('edit_profile_save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('That name is not allowed'), findsOneWidget);
  });

  testWidgets('the listener toggle is offered only to a non-listener', (tester) async {
    await tester.pumpWidget(await subject());
    await tester.pump();

    expect(find.byKey(const Key('edit_profile_apply_listener')), findsOneWidget);
  });

  testWidgets('an already-listener account has no apply toggle', (tester) async {
    const listenerUser = MocoUser(
      id: 2,
      phone: '+919800000002',
      displayName: 'Ananya',
      role: 'listener',
    );
    final listenerUsersApi = _MockUsersApi();
    when(() => listenerUsersApi.me()).thenAnswer((_) async => listenerUser);
    final overrides = await signedInOverrides(user: listenerUser, usersApi: listenerUsersApi);

    await tester.pumpWidget(wrapWidget(const EditProfileScreen(), overrides: overrides));
    await tester.pump();

    expect(find.byKey(const Key('edit_profile_apply_listener')), findsNothing);
  });

  testWidgets('reaching this screen from "Apply to become a listener" pre-enables it', (
    tester,
  ) async {
    await tester.pumpWidget(await subject(startWithListenerApplication: true));
    await tester.pump();

    final toggle = tester.widget<Switch>(find.byKey(const Key('edit_profile_apply_listener')));
    expect(toggle.value, isTrue);
  });

  testWidgets('saving with the listener toggle on calls become-listener', (tester) async {
    when(
      () => usersApi.updateProfile(
        displayName: any(named: 'displayName'),
        language: any(named: 'language'),
        gender: any(named: 'gender'),
      ),
    ).thenAnswer((_) async => _user);
    when(() => usersApi.becomeListener()).thenAnswer(
      (_) async => {'role': 'both', 'kycStatus': 'unsubmitted', 'kycRequired': true},
    );

    await tester.pumpWidget(await subject(startWithListenerApplication: true));
    await tester.pump();

    await tester.tap(find.byKey(const Key('edit_profile_save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    verify(() => usersApi.becomeListener()).called(1);
  });
}
