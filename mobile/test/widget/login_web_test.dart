import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/config_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/platform/platform_capabilities.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/core/widgets/moco_app_frame.dart';
import 'package:moco/features/auth/login_screen.dart';
import 'package:moco/features/auth/widgets/login_backdrop.dart';
import 'package:moco/shared/models/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

/// The web login layout: full-screen background, Email | SMS glass toggle,
/// one glass input, the pill action — on the same auth logic as Android.

class _MockAuthApi extends Mock implements AuthApi {}

class _MockUsersApi extends Mock implements UsersApi {}

class _FakeConfigApi extends Mock implements ConfigApi {
  _FakeConfigApi(this.available, this.background);

  final Set<OtpChannel> available;
  final LoginBackground? background;

  @override
  Future<AppConfig> fetch() async => AppConfig(
    rates: const CallRates(audio: 6, video: 12),
    auth: AuthConfig(available: available),
    loginBackground: background,
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

void main() {
  late _MockAuthApi authApi;
  late AppPreferences prefs;

  setUpAll(() => registerFallbackValue(OtpChannel.email));

  setUp(() async {
    authApi = _MockAuthApi();
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.create();
  });

  Widget subject({
    Set<OtpChannel> available = const {OtpChannel.email, OtpChannel.sms},
    LoginBackground? background,
  }) => wrapWidget(
    const LoginScreen(),
    overrides: [
      appPreferencesProvider.overrideWithValue(prefs),
      secureStoreProvider.overrideWithValue(_FakeStore()),
      authApiProvider.overrideWithValue(authApi),
      usersApiProvider.overrideWithValue(_MockUsersApi()),
      configApiProvider.overrideWithValue(
        _FakeConfigApi(available, background),
      ),
      platformCapabilitiesProvider.overrideWithValue(
        const PlatformCapabilities(isWeb: true),
      ),
    ],
  );

  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  bool selected(WidgetTester tester, String channel) =>
      tester
          .getSemantics(find.byKey(Key('login_channel_$channel')))
          .flagsCollection
          .isSelected ==
      ui.Tristate.isTrue;

  void stubSend() {
    when(
      () => authApi.sendOtp(
        channel: any(named: 'channel'),
        identifier: any(named: 'identifier'),
      ),
    ).thenAnswer((_) async => const OtpSent(expiresIn: 300, resendIn: 30));
  }

  testWidgets('web: immersive layout — Email | SMS only, Email by default', (
    tester,
  ) async {
    await pump(tester, subject());

    expect(find.byType(LoginBackdrop), findsOneWidget);
    // Minimal first screen: no title card, no WhatsApp/Telegram.
    expect(find.text('Login / Registration'), findsNothing);
    expect(find.byKey(const Key('login_channel_whatsapp')), findsNothing);
    expect(find.byKey(const Key('login_channel_telegram')), findsNothing);
    expect(selected(tester, 'email'), isTrue);
    expect(find.text('Type Email Id'), findsOneWidget);
    expect(find.byKey(const Key('login_send_code')), findsOneWidget);
  });

  testWidgets('web: SMS switches the input to the phone field', (tester) async {
    await pump(tester, subject());

    await tester.tap(find.byKey(const Key('login_channel_sms')));
    await tester.pumpAndSettle();

    expect(selected(tester, 'sms'), isTrue);
    expect(find.byKey(const Key('login_phone_field')), findsOneWidget);
    expect(find.byKey(const Key('login_email_field')), findsNothing);
    final field = tester.widget<TextField>(
      find.byKey(const Key('login_phone_field')),
    );
    expect(field.keyboardType, TextInputType.phone);
  });

  testWidgets('web: SMS cannot be picked when it is not configured', (
    tester,
  ) async {
    await pump(tester, subject(available: const {OtpChannel.email}));

    await tester.tap(find.byKey(const Key('login_channel_sms')));
    await tester.pumpAndSettle();

    expect(selected(tester, 'email'), isTrue);
    expect(find.byKey(const Key('login_email_field')), findsOneWidget);
  });

  testWidgets(
    'web: the pill sends the existing OTP request once input is valid',
    (tester) async {
      stubSend();
      await pump(tester, subject());

      await tester.tap(find.byKey(const Key('login_send_code')));
      await tester.pump();
      verifyNever(
        () => authApi.sendOtp(
          channel: any(named: 'channel'),
          identifier: any(named: 'identifier'),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('login_email_field')),
        'asha@example.com',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('login_send_code')));
      await tester.pumpAndSettle();

      verify(
        () => authApi.sendOtp(
          channel: OtpChannel.email,
          identifier: 'asha@example.com',
        ),
      ).called(1);
      expect(find.byKey(const Key('login_code_field')), findsOneWidget);
      expect(find.byKey(const Key('login_sent_to')), findsOneWidget);
    },
  );

  testWidgets('web: a wrong code shows the error and keeps the step', (
    tester,
  ) async {
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
        message: 'Incorrect code',
      ),
    );
    await pump(tester, subject());
    await tester.enterText(
      find.byKey(const Key('login_email_field')),
      'asha@example.com',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_send_code')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('login_code_field')), '000000');
    await tester.pump();
    await tester.tap(find.byKey(const Key('login_verify')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login_error')), findsOneWidget);
    expect(find.text('Invalid code'), findsOneWidget);
    expect(find.byKey(const Key('login_code_field')), findsOneWidget);
  });

  testWidgets('web: a configured image background is shown', (tester) async {
    await pump(
      tester,
      subject(
        background: const LoginBackground(
          isVideo: false,
          imageUrl: 'https://example.invalid/bg.jpg',
        ),
      ),
    );
    expect(find.byKey(const Key('login_bg_image')), findsOneWidget);
  });

  testWidgets('web: a video that cannot play leaves the image fallback', (
    tester,
  ) async {
    await pump(
      tester,
      subject(
        background: const LoginBackground(
          isVideo: true,
          imageUrl: 'https://example.invalid/bg.jpg',
          videoUrl: 'https://example.invalid/bg.mp4',
        ),
      ),
    );
    // No video plugin in tests = the "cannot play" case: no crash, image stays.
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('login_bg_image')), findsOneWidget);
    expect(find.byKey(const Key('login_send_code')), findsOneWidget);
  });

  testWidgets('web: the login fills the window, then gives the frame back', (
    tester,
  ) async {
    await pump(tester, subject());
    expect(MocoAppFrame.fullBleedRequests.value, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(MocoAppFrame.fullBleedRequests.value, 0);
  });

  test('loginBackground config parsing', () {
    expect(LoginBackground.fromJson(null), isNull);
    expect(LoginBackground.fromJson({'type': 'image'}), isNull);
    final image = LoginBackground.fromJson({
      'type': 'image',
      'imageUrl': 'https://x/i.jpg',
    })!;
    expect(image.isVideo, isFalse);
    final video = LoginBackground.fromJson({
      'type': 'video',
      'imageUrl': 'https://x/i.jpg',
      'videoUrl': 'https://x/v.mp4',
    })!;
    expect(video.isVideo, isTrue);
    expect(video.imageUrl, 'https://x/i.jpg');
  });
}
