import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/auth/auth_controller.dart';
import 'package:moco/core/monitoring/monitoring.dart';
import 'package:moco/core/push/push_service.dart';
import 'package:moco/core/routing/app_router.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/shared/models/user.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('push notification taps', () {
    test('open the screen that matches the notification type', () {
      expect(PushService.locationFor('payout_paid'), Routes.earningsLedger);
      expect(PushService.locationFor('payout_approved'), Routes.earningsLedger);
      expect(PushService.locationFor('test'), Routes.notifications);
      expect(PushService.locationFor('kyc_approved'), Routes.notifications);
      expect(PushService.locationFor(null), Routes.notifications);
    });

    test('an incoming call only brings the app forward', () {
      // The realtime connection shows the call screen if it is still ringing.
      expect(PushService.locationFor('incoming_call'), isNull);
    });

    test(
      'without Firebase (tests, web) every push method is a no-op',
      () async {
        final push = PushService(usersApi: _RecordingUsersApi());
        expect(push.isEnabled, isFalse);
        await push.onSignedIn();
        await push.onSigningOut();
        await push.start(open: (_) => fail('nothing to open'));
      },
    );
  });

  group('sign-out', () {
    late _FakeStore store;
    late AuthController controller;

    setUp(() async {
      final usersApi = _MockUsersApi();
      store = _FakeStore();
      SharedPreferences.setMockInitialValues({});
      controller = AuthController(
        authApi: _MockAuthApi(),
        usersApi: usersApi,
        store: store,
        prefs: await AppPreferences.create(),
      );
      when(() => usersApi.me()).thenAnswer(
        (_) async =>
            const MocoUser(id: 1, phone: '+919876543210', displayName: 'Rahul'),
      );
      await controller.bootstrap();
    });

    test(
      'runs the pre-sign-out hook while the session is still stored',
      () async {
        String? tokenDuringHook;
        controller.onSigningOut = () async =>
            tokenDuringHook = await store.readToken();
        await controller.signOut();
        expect(tokenDuringHook, 'jwt');
        expect(store.token, isNull);
      },
    );

    test('a failing hook never blocks sign-out', () async {
      controller.onSigningOut = () async => throw Exception('offline');
      await controller.signOut();
      expect(controller.value.isSignedIn, isFalse);
      expect(store.token, isNull);
    });
  });

  group('error reporting privacy', () {
    test('is off without a DSN', () {
      expect(Monitoring.enabled, isFalse);
    });

    test('breadcrumb URLs lose their query string and bodies are dropped', () {
      final crumb = Breadcrumb(
        category: 'http',
        data: {
          'url': 'https://api.lovcamx.online/api/auth/otp/verify?code=123456',
          'method': 'POST',
          'body': '{"code":"123456"}',
        },
      );
      final clean = Monitoring.scrubBreadcrumb(crumb, Hint())!;
      expect(
        clean.data!['url'],
        'https://api.lovcamx.online/api/auth/otp/verify',
      );
      expect(clean.data!.containsKey('body'), isFalse);
      expect(clean.data!['method'], 'POST');
    });

    test('events keep only the method and path of a request', () async {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://lovcamx.online/login?token=abc#x',
          method: 'GET',
          headers: {'Authorization': 'Bearer secret'},
          cookies: 'session=secret',
          data: {'code': '123456'},
        ),
      );
      final clean = (await Monitoring.scrubEvent(event, Hint()))!;
      expect(clean.request!.url, 'https://lovcamx.online/login');
      expect(clean.request!.method, 'GET');
      expect(clean.request!.headers, isEmpty);
      expect(clean.request!.cookies, isNull);
      expect(clean.request!.data, isNull);
    });
  });
}

class _RecordingUsersApi extends Fake implements UsersApi {}

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
