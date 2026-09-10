import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/auth/login_screen.dart';
import 'package:moco/features/discovery/discovery_screen.dart';
import 'package:moco/features/listener_profile/listener_profile_screen.dart';
import 'package:moco/features/onboarding/onboarding_screen.dart';
import 'package:moco/features/profile_setup/profile_setup_screen.dart';
import 'package:moco/shared/models/listener.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockUsersApi extends Mock implements UsersApi {}

class _MockAuthApi extends Mock implements AuthApi {}

/// The device widths the app must hold up at.
///
/// 360 is the common budget-Android floor and the tightest case; 390 is an
/// iPhone 14/15; 430 is a Pro Max. Heights are the matching real values, since
/// a too-tall surface hides vertical overflow.
const _sizes = <String, Size>{
  '360x800': Size(360, 800),
  '390x844': Size(390, 844),
  '430x932': Size(430, 932),
};

ListenerSummary _summary(int id, String name) => ListenerSummary(
  id: id,
  displayName: name,
  audioRate: 6,
  videoRate: 12,
  isOnline: true,
  verified: true,
  languages: const ['hi', 'en'],
  rating: 4.8,
  totalCalls: 214,
);

const _detail = ListenerDetail(
  id: 7,
  displayName: 'Priyadarshini Venkataraman',
  bio:
      'Here to listen, any time of day. I speak Hindi, Telugu and English, and '
      'I am happiest talking about films, family and everything in between.',
  languages: ['hi', 'te', 'en'],
  audioRate: 6,
  videoRate: 12,
  verified: true,
  isOnline: true,
  rating: 4.9,
  ratingCount: 1284,
  totalCalls: 3672,
  followerCount: 1042,
);

/// Fails the test if Flutter reported a layout overflow while pumping.
///
/// Overflow is reported as a FlutterError to the framework, not as an
/// exception the widget throws, so it has to be collected deliberately.
Future<void> expectNoOverflow(
  WidgetTester tester,
  Widget widget, {
  required Size size,
  required String label,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final errors = <String>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
  };

  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();

  FlutterError.onError = previousOnError;

  final overflows = errors.where((e) => e.contains('overflowed')).toList();
  expect(
    overflows,
    isEmpty,
    reason: '$label overflowed at ${size.width.toInt()}px: $overflows',
  );
}

void main() {
  late List<Override> base;
  late _MockListenersApi listenersApi;
  late _MockUsersApi usersApi;

  setUpAll(() => registerFallbackValue(const DiscoveryFilters()));

  setUp(() async {
    base = await baseOverrides();
    listenersApi = _MockListenersApi();
    usersApi = _MockUsersApi();

    when(
      () => listenersApi.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => DiscoveryPage(
        listeners: [
          _summary(1, 'Priya'),
          // A deliberately long name: truncation, not overflow, is correct.
          _summary(2, 'Priyadarshini Venkataraman'),
          _summary(3, 'Kavya'),
          _summary(4, 'Ananya'),
        ],
      ),
    );
    // Scoped to limit: 10 — the similar-listeners call — so it cannot shadow
    // the discovery stub above, which uses the default limit.
    when(() => listenersApi.discover(filters: any(named: 'filters'), limit: 10))
        .thenAnswer((_) async => const DiscoveryPage());
    when(() => listenersApi.byId(any())).thenAnswer((_) async => _detail);
  });

  for (final entry in _sizes.entries) {
    final label = entry.key;
    final size = entry.value;

    group('at $label', () {
      testWidgets('onboarding does not overflow', (tester) async {
        await expectNoOverflow(
          tester,
          wrapRoutedScreen(const OnboardingScreen(), overrides: [...base]),
          size: size,
          label: 'Onboarding',
        );
      });

      testWidgets('login does not overflow', (tester) async {
        await expectNoOverflow(
          tester,
          wrapWidget(
            const LoginScreen(),
            overrides: [
              ...base,
              authApiProvider.overrideWithValue(_MockAuthApi()),
              usersApiProvider.overrideWithValue(usersApi),
            ],
          ),
          size: size,
          label: 'Login',
        );
      });

      testWidgets('profile setup does not overflow', (tester) async {
        await expectNoOverflow(
          tester,
          wrapWidget(
            const ProfileSetupScreen(),
            overrides: [
              ...base,
              usersApiProvider.overrideWithValue(usersApi),
              authApiProvider.overrideWithValue(_MockAuthApi()),
            ],
          ),
          size: size,
          label: 'Profile setup',
        );
      });

      testWidgets('discovery grid does not overflow', (tester) async {
        await expectNoOverflow(
          tester,
          wrapShellScreen(
            const DiscoveryScreen(),
            overrides: [
              ...base,
              listenersApiProvider.overrideWithValue(listenersApi),
            ],
          ),
          size: size,
          label: 'Discovery',
        );
      });

      testWidgets('listener profile does not overflow', (tester) async {
        await expectNoOverflow(
          tester,
          wrapWidget(
            const ListenerProfileScreen(listenerId: 7),
            overrides: [
              ...base,
              listenersApiProvider.overrideWithValue(listenersApi),
            ],
          ),
          size: size,
          label: 'Listener profile',
        );
      });
    });
  }

  testWidgets('a long listener name truncates rather than overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrapShellScreen(
        const DiscoveryScreen(),
        overrides: [
          ...base,
          listenersApiProvider.overrideWithValue(listenersApi),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The card for the long-named listener must ellipsise, which is what keeps
    // the 360px grid from overflowing.
    final nameFinder = find.descendant(
      of: find.byKey(const Key('listener_card_2')),
      matching: find.text('Priyadarshini Venkataraman'),
    );
    expect(nameFinder, findsOneWidget);

    final nameText = tester.widget<Text>(nameFinder);
    expect(nameText.overflow, TextOverflow.ellipsis);
    expect(nameText.maxLines, 1);
  });
}
