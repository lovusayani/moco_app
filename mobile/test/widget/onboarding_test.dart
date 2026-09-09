import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/features/onboarding/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

void main() {
  late AppPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.create();
  });

  Widget subject() => wrapRoutedScreen(
    const OnboardingScreen(),
    overrides: [appPreferencesProvider.overrideWithValue(prefs)],
  );

  testWidgets('starts on the first page with a Next call to action', (
    tester,
  ) async {
    await tester.pumpWidget(subject());

    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Get started'), findsNothing);
    expect(find.byKey(const Key('onboarding_skip')), findsOneWidget);
  });

  testWidgets('advances through every page and ends on Get started', (
    tester,
  ) async {
    await tester.pumpWidget(subject());

    // Two taps of Next moves through the three pages.
    await tester.tap(find.byKey(const Key('onboarding_cta')));
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding_cta')));
    await tester.pumpAndSettle();

    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('finishing persists completion so it is not shown again', (
    tester,
  ) async {
    await tester.pumpWidget(subject());
    expect(prefs.onboardingComplete, isFalse);

    await tester.tap(find.byKey(const Key('onboarding_skip')));
    await tester.pumpAndSettle();

    expect(prefs.onboardingComplete, isTrue);
  });
}
