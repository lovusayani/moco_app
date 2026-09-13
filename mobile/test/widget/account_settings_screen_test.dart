import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/auth/auth_state.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/profile/account_settings_screen.dart';
import 'package:moco/shared/models/user.dart';

import '../support/harness.dart';

class _MockUsersApi extends Mock implements UsersApi {}

const _user = MocoUser(id: 1, phone: '+919876543210', displayName: 'Rahul');

void main() {
  late _MockUsersApi usersApi;
  late ProviderContainer container;

  setUp(() {
    usersApi = _MockUsersApi();
    when(() => usersApi.me()).thenAnswer((_) async => _user);
  });

  /// Builds the screen inside a container this test holds onto, so it can
  /// assert on session state directly rather than inferring it from what the
  /// (deliberately minimal) settings screen happens to render after signing
  /// out or deleting the account.
  Future<Widget> subject() async {
    final overrides = await signedInOverrides(user: _user, usersApi: usersApi);
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MocoTheme.dark, home: const AccountSettingsScreen()),
    );
  }

  testWidgets('shows the signed-in phone number', (tester) async {
    await tester.pumpWidget(await subject());
    await tester.pump();

    expect(find.text('+919876543210'), findsOneWidget);
  });

  testWidgets('sign out requires confirmation, then clears the session', (tester) async {
    final widget = await subject();
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.tap(find.byKey(const Key('account_settings_logout')));
    await tester.pumpAndSettle();

    expect(find.text('Sign out?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm_sign_out')));
    await tester.pumpAndSettle();

    expect(container.read(authControllerProvider).status, AuthStatus.unauthenticated);
  });

  testWidgets('dismissing the sign-out dialog changes nothing', (tester) async {
    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.tap(find.byKey(const Key('account_settings_logout')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').first);
    await tester.pumpAndSettle();

    expect(container.read(authControllerProvider).status, AuthStatus.authenticated);
  });

  testWidgets('deletion requires confirmation, then calls the backend and signs out', (
    tester,
  ) async {
    when(() => usersApi.deleteAccount()).thenAnswer((_) async {});

    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.tap(find.byKey(const Key('account_settings_delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete your account?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm_delete_account')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    verify(() => usersApi.deleteAccount()).called(1);
    expect(container.read(authControllerProvider).status, AuthStatus.unauthenticated);
  });

  testWidgets('dismissing the deletion dialog calls nothing', (tester) async {
    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.tap(find.byKey(const Key('account_settings_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').first);
    await tester.pumpAndSettle();

    verifyNever(() => usersApi.deleteAccount());
  });

  testWidgets('a failed deletion shows an error and keeps the session', (tester) async {
    when(() => usersApi.deleteAccount()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'No internet connection'),
    );

    await tester.pumpWidget(await subject());
    await tester.pump();

    await tester.tap(find.byKey(const Key('account_settings_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete_account')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('No internet connection'), findsOneWidget);
    expect(container.read(authControllerProvider).status, AuthStatus.authenticated);
  });
}
