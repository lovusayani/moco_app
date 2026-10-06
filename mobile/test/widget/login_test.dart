import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/config_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/features/auth/login_screen.dart';
import 'package:moco/shared/models/app_config.dart';
import 'package:moco/shared/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

class _MockAuthApi extends Mock implements AuthApi {}

class _MockUsersApi extends Mock implements UsersApi {}

/// `GET /config` as the backend reports it; [available] are the configured
/// sign-in methods.
class _FakeConfigApi extends Mock implements ConfigApi {
  _FakeConfigApi(this.available);

  final Set<OtpChannel> available;

  @override
  Future<AppConfig> fetch() async => AppConfig(
    rates: const CallRates(audio: 6, video: 12),
    auth: AuthConfig(available: available),
  );
}

class _FakeStore implements SecureStore {
  String? token;
  @override
  Future<void> clear() async => token = null;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String value) async => token = value;
}

const _session = AuthSession(
  token: 'jwt-token',
  isNew: true,
  user: AuthUser(id: 1, phone: '', email: 'asha@example.com'),
);

void main() {
  late _MockAuthApi authApi;
  late _MockUsersApi usersApi;
  late _FakeStore store;
  late AppPreferences prefs;

  setUpAll(() => registerFallbackValue(OtpChannel.email));

  setUp(() async {
    authApi = _MockAuthApi();
    usersApi = _MockUsersApi();
    store = _FakeStore();
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.create();
  });

  Widget subject({Set<OtpChannel> available = const {OtpChannel.email}}) =>
      wrapWidget(
        const LoginScreen(),
        overrides: [
          appPreferencesProvider.overrideWithValue(prefs),
          secureStoreProvider.overrideWithValue(store),
          authApiProvider.overrideWithValue(authApi),
          usersApiProvider.overrideWithValue(usersApi),
          configApiProvider.overrideWithValue(_FakeConfigApi(available)),
        ],
      );

  void stubSend({int resendIn = 30}) {
    when(
      () => authApi.sendOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
      ),
    ).thenAnswer((_) async => OtpSent(expiresIn: 300, resendIn: resendIn));
  }

  Future<void> enterEmailAndSend(
    WidgetTester tester, [
    String email = 'asha@example.com',
  ]) async {
    await tester.enterText(find.byKey(const Key('login_email_field')), email);
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pumpAndSettle();
  }

  bool selected(WidgetTester tester, String channel) =>
      tester
          .getSemantics(find.byKey(Key('login_channel_$channel')))
          .flagsCollection
          .isSelected ==
      ui.Tristate.isTrue;

  testWidgets(
    '14 + 16. Email is selected by default and only the email field shows',
    (tester) async {
      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();

      expect(find.text('Login / Registration'), findsOneWidget);
      expect(selected(tester, 'email'), isTrue);
      expect(find.byKey(const Key('login_email_field')), findsOneWidget);
      expect(find.byKey(const Key('login_phone_field')), findsNothing);
    },
  );

  testWidgets('the send button stays disabled until the email is valid', (
    tester,
  ) async {
    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('login_email_field')), 'asha@');
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pump();

    verifyNever(
      () => authApi.sendOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
      ),
    );
  });

  testWidgets(
    '15 + 17. switching to an available phone method shows the phone field',
    (tester) async {
      stubSend();
      await tester.pumpWidget(
        subject(available: {OtpChannel.email, OtpChannel.sms}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('login_channel_sms')));
      await tester.pumpAndSettle();

      expect(selected(tester, 'sms'), isTrue);
      expect(find.byKey(const Key('login_phone_field')), findsOneWidget);
      expect(find.byKey(const Key('login_email_field')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('login_phone_field')),
        '9876543210',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('login_send_code')));
      await tester.pumpAndSettle();

      verify(
        () => authApi.sendOtp(
          channel: OtpChannel.sms,
          identifier: '+919876543210',
        ),
      ).called(1);
      expect(find.text('+919876543210 by SMS'), findsOneWidget);
    },
  );

  testWidgets(
    'an unconfigured method is shown as "Soon" and cannot be selected',
    (tester) async {
      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();

      expect(find.text('Soon'), findsNWidgets(3));
      await tester.tap(find.byKey(const Key('login_channel_whatsapp')));
      await tester.pumpAndSettle();

      expect(selected(tester, 'email'), isTrue);
      expect(find.byKey(const Key('login_email_field')), findsOneWidget);
    },
  );

  testWidgets(
    '18. email flow: send, see where it went, verify, session stored',
    (tester) async {
      stubSend();
      when(
        () => authApi.verifyOtp(
          channel: OtpChannel.email,
          identifier: 'asha@example.com',
          code: '482913',
        ),
      ).thenAnswer((_) async => _session);
      when(() => usersApi.me()).thenAnswer(
        (_) async =>
            const MocoUser(id: 1, phone: '', email: 'asha@example.com'),
      );

      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();
      await enterEmailAndSend(tester);

      verify(
        () => authApi.sendOtp(
          channel: OtpChannel.email,
          identifier: 'asha@example.com',
        ),
      ).called(1);
      expect(find.text('We sent a verification code to'), findsOneWidget);
      expect(find.text('asha@example.com'), findsOneWidget);
      expect(find.text('Change email'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('login_code_field')),
        '482913',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('login_verify')));
      // The app router navigates away on success; here the button keeps its
      // spinner, so pump rather than settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(store.token, 'jwt-token');
    },
  );

  testWidgets(
    'an invalid code shows "Invalid code" and keeps the user on the step',
    (tester) async {
      stubSend();
      when(
        () => authApi.verifyOtp(
          channel: any(named: 'channel'),
          identifier: any(named: 'identifier'),
          code: any(named: 'code'),
        ),
      ).thenThrow(
        const ApiException(
          kind: ApiErrorKind.unauthorized,
          code: 'unauthorized',
          message: 'Incorrect code',
        ),
      );

      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();
      await enterEmailAndSend(tester);
      await tester.enterText(
        find.byKey(const Key('login_code_field')),
        '000000',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('login_verify')));
      await tester.pumpAndSettle();

      expect(find.text('Invalid code'), findsOneWidget);
      expect(find.byKey(const Key('login_code_field')), findsOneWidget);
      expect(store.token, isNull);
    },
  );

  testWidgets('an expired code says so and clears the field', (tester) async {
    stubSend();
    when(
      () => authApi.verifyOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
        code: any(named: 'code'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        code: 'otp_expired',
        message: 'expired',
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    await enterEmailAndSend(tester);
    await tester.enterText(find.byKey(const Key('login_code_field')), '111111');
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_verify')));
    await tester.pumpAndSettle();

    expect(find.text('Code expired. Request a new one.'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('login_code_field')),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('a rate limit is surfaced in plain words', (tester) async {
    when(
      () => authApi.sendOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.rateLimited,
        code: 'rate_limited',
        message: 'x',
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    await enterEmailAndSend(tester);

    expect(
      find.text('Too many attempts. Please try again later.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('login_email_field')), findsOneWidget);
  });

  testWidgets('a failed email send says "Unable to send email"', (
    tester,
  ) async {
    when(
      () => authApi.sendOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.server,
        code: 'otp_delivery_failed',
        message: 'provider said x',
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    await enterEmailAndSend(tester);

    expect(
      find.text('Unable to send email. Please try again later.'),
      findsOneWidget,
    );
    expect(find.textContaining('provider said'), findsNothing);
  });

  testWidgets('19. resend waits out the countdown, then sends again', (
    tester,
  ) async {
    stubSend(resendIn: 30);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    await enterEmailAndSend(tester);

    expect(find.text('Resend code in 30s'), findsOneWidget);
    await tester.tap(find.byKey(const Key('login_resend')));
    await tester.pump();
    verify(
      () => authApi.sendOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
      ),
    ).called(1);

    await tester.pump(const Duration(seconds: 31));
    expect(find.text('Resend code'), findsOneWidget);
    await tester.tap(find.byKey(const Key('login_resend')));
    await tester.pumpAndSettle();
    verify(
      () => authApi.sendOtp(
        channel: OtpChannel.email,
        identifier: 'asha@example.com',
      ),
    ).called(1);
    expect(find.text('Resend code in 30s'), findsOneWidget);
  });

  testWidgets('"Change email" returns to the form with the address kept', (
    tester,
  ) async {
    stubSend();
    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    await enterEmailAndSend(tester);

    await tester.tap(find.byKey(const Key('login_change_identifier')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('login_email_field')),
    );
    expect(field.controller!.text, 'asha@example.com');
    expect(find.byKey(const Key('login_channel_email')), findsOneWidget);
  });

  testWidgets('20. desktop: the form is centred both ways and not too wide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    final form = tester.getRect(find.byKey(const Key('login_form')));
    expect(form.width, lessThanOrEqualTo(420));
    expect(
      (form.center.dx - 720).abs(),
      lessThan(2),
      reason: 'horizontally centred',
    );
    expect(
      (form.center.dy - 450).abs(),
      lessThan(40),
      reason: 'vertically centred',
    );
  });

  testWidgets(
    '21. phone width: the form fits with side padding and no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();

      final form = tester.getRect(find.byKey(const Key('login_form')));
      expect(form.left, greaterThanOrEqualTo(16));
      expect(form.right, lessThanOrEqualTo(344));
      expect(tester.takeException(), isNull);
    },
  );
}
