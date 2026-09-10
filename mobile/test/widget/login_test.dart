import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/features/auth/login_screen.dart';
import 'package:moco/shared/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

class _MockAuthApi extends Mock implements AuthApi {}

class _MockUsersApi extends Mock implements UsersApi {}

class _FakeStore implements SecureStore {
  String? token;
  @override
  Future<void> clear() async => token = null;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String value) async => token = value;
}

void main() {
  late _MockAuthApi authApi;
  late _MockUsersApi usersApi;
  late _FakeStore store;
  late AppPreferences prefs;

  setUp(() async {
    authApi = _MockAuthApi();
    usersApi = _MockUsersApi();
    store = _FakeStore();
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.create();
  });

  Widget subject() => wrapWidget(
    const LoginScreen(),
    overrides: [
      appPreferencesProvider.overrideWithValue(prefs),
      secureStoreProvider.overrideWithValue(store),
      authApiProvider.overrideWithValue(authApi),
      usersApiProvider.overrideWithValue(usersApi),
    ],
  );

  Future<void> enterPhone(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('login_phone_field')),
      '9876543210',
    );
    await tester.pump();
  }

  testWidgets('the send button stays disabled until the number is complete', (
    tester,
  ) async {
    await tester.pumpWidget(subject());

    await tester.enterText(find.byKey(const Key('login_phone_field')), '98765');
    await tester.pump();

    // A short number must not reach the backend and burn a rate-limit slot.
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();
    verifyNever(() => authApi.requestOtp(any()));
  });

  testWidgets('requesting a code moves to the code step', (tester) async {
    when(() => authApi.requestOtp(any())).thenAnswer((_) async => 300);

    await tester.pumpWidget(subject());
    await enterPhone(tester);
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The number is sent in E.164, as the backend's zod schema requires.
    verify(() => authApi.requestOtp('+919876543210')).called(1);
    expect(find.byKey(const Key('login_code_field')), findsOneWidget);
    expect(find.byKey(const Key('login_verify')), findsOneWidget);
  });

  testWidgets('a rate-limit error is surfaced, not swallowed', (tester) async {
    when(() => authApi.requestOtp(any())).thenThrow(
      const ApiException(
        kind: ApiErrorKind.rateLimited,
        message: 'Too many attempts. Please wait a moment and try again.',
      ),
    );

    await tester.pumpWidget(subject());
    await enterPhone(tester);
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('login_error')), findsOneWidget);
    expect(find.textContaining('Too many attempts'), findsOneWidget);
    // It must stay on the phone step — no code was actually sent.
    expect(find.byKey(const Key('login_code_field')), findsNothing);
  });

  testWidgets('an invalid code shows an error and keeps the user on the step', (
    tester,
  ) async {
    when(() => authApi.requestOtp(any())).thenAnswer((_) async => 300);
    when(
      () => authApi.verifyOtp(
        phone: any(named: 'phone'),
        code: any(named: 'code'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.unauthorized,
        message: 'Incorrect code',
      ),
    );

    await tester.pumpWidget(subject());
    await enterPhone(tester);
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byKey(const Key('login_code_field')), '000000');
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_verify')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Incorrect code'), findsOneWidget);
    // No token may be stored on a failed verify.
    expect(store.token, isNull);
  });

  testWidgets('a successful verify stores the session token', (tester) async {
    when(() => authApi.requestOtp(any())).thenAnswer((_) async => 300);
    when(
      () => authApi.verifyOtp(
        phone: any(named: 'phone'),
        code: any(named: 'code'),
      ),
    ).thenAnswer(
      (_) async => const AuthSession(
        token: 'jwt-token',
        isNew: true,
        user: AuthUser(id: 1, phone: '+919876543210'),
      ),
    );
    when(() => usersApi.me())
        .thenAnswer((_) async => const MocoUser(id: 1, phone: '+919876543210'));

    await tester.pumpWidget(subject());
    await enterPhone(tester);
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byKey(const Key('login_code_field')), '123456');
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_verify')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(store.token, 'jwt-token');
  });

  testWidgets('resend is blocked while the timer runs', (tester) async {
    when(() => authApi.requestOtp(any())).thenAnswer((_) async => 300);

    await tester.pumpWidget(subject());
    await enterPhone(tester);
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final resend = tester.widget<TextButton>(
      find.byKey(const Key('login_resend')),
    );
    // Disabled, so a user cannot spend their 5-per-hour allowance instantly.
    expect(resend.onPressed, isNull);
    expect(find.textContaining('Resend code in'), findsOneWidget);
  });
}
