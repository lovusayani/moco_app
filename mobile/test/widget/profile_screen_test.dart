import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/api/payouts_api.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/profile/profile_screen.dart';
import 'package:moco/shared/models/earnings.dart';
import 'package:moco/shared/models/user.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockPayoutsApi extends Mock implements PayoutsApi {}

const _caller = MocoUser(id: 1, phone: '+919876543210', displayName: 'Rahul');

const _bothRoleUser = MocoUser(
  id: 2,
  phone: '+919800000002',
  displayName: 'Priya',
  role: 'both',
  listener: ListenerState(isOnline: false, kycStatus: 'approved'),
);

const _pendingListenerUser = MocoUser(
  id: 3,
  phone: '+919800000003',
  displayName: 'Ananya',
  role: 'both',
  listener: ListenerState(kycStatus: 'pending'),
);

const _earnings = EarningsSummary(
  balance: 250,
  lifetime: 900,
  today: 20,
  thisMonth: 150,
  totalCalls: 30,
  rating: 4.7,
  minWithdrawal: 100,
  canWithdraw: true,
);

void main() {
  late _MockListenersApi listenersApi;
  late _MockPayoutsApi payoutsApi;

  setUp(() {
    listenersApi = _MockListenersApi();
    payoutsApi = _MockPayoutsApi();
    when(() => payoutsApi.earnings()).thenAnswer((_) async => _earnings);
  });

  Widget subject(MocoUser user) {
    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        GoRoute(
          path: '/profile',
          builder: (_, __) => const Scaffold(body: ProfileScreen()),
        ),
        GoRoute(
          path: '/profile/edit',
          builder: (_, __) => const Scaffold(body: Text('edit screen')),
        ),
        GoRoute(
          path: '/profile/settings',
          builder: (_, __) => const Scaffold(body: Text('settings screen')),
        ),
        GoRoute(
          path: '/profile/ledger/coins',
          builder: (_, __) => const Scaffold(body: Text('coin ledger screen')),
        ),
        GoRoute(
          path: '/profile/ledger/earnings',
          builder: (_, __) => const Scaffold(body: Text('earnings ledger screen')),
        ),
      ],
    );

    return FutureBuilder<List<Override>>(
      future: signedInOverrides(user: user),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        return ProviderScope(
          overrides: [
            ...snapshot.data!,
            listenersApiProvider.overrideWithValue(listenersApi),
            payoutsApiProvider.overrideWithValue(payoutsApi),
          ],
          child: MaterialApp.router(theme: MocoTheme.dark, routerConfig: router),
        );
      },
    );
  }

  Future<void> pumpReady(WidgetTester tester, MocoUser user) async {
    await tester.pumpWidget(subject(user));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('shows the signed-in user\'s name and phone', (tester) async {
    await pumpReady(tester, _caller);

    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('+919876543210'), findsOneWidget);
  });

  testWidgets('a caller-only account has no role switch and no listener section', (tester) async {
    await pumpReady(tester, _caller);

    expect(find.byKey(const Key('profile_role_switch')), findsNothing);
    expect(find.byKey(const Key('profile_availability_card')), findsNothing);
    expect(find.byKey(const Key('profile_become_listener_row')), findsOneWidget);
  });

  testWidgets('a both-role account shows the role switch, defaulting to Calling', (tester) async {
    await pumpReady(tester, _bothRoleUser);

    expect(find.byKey(const Key('profile_role_switch')), findsOneWidget);
    expect(find.byKey(const Key('profile_wallet_row')), findsOneWidget);
    expect(find.byKey(const Key('profile_availability_card')), findsNothing);
  });

  testWidgets('switching to Listening reveals listener sections, hides caller ones', (tester) async {
    await pumpReady(tester, _bothRoleUser);

    await tester.tap(find.byKey(const Key('profile_role_listener')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('profile_wallet_row')), findsNothing);
    expect(find.byKey(const Key('profile_availability_card')), findsOneWidget);
    verify(() => payoutsApi.earnings()).called(1);
  });

  testWidgets('an unapproved listener sees status but no availability switch', (tester) async {
    await pumpReady(tester, _pendingListenerUser);

    await tester.tap(find.byKey(const Key('profile_role_listener')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Verification pending'), findsOneWidget);
    expect(
      find.byKey(const Key('profile_availability_switch')),
      findsNothing,
      reason: 'an unapproved listener must not be offered an online toggle',
    );
  });

  testWidgets('toggling availability calls the backend', (tester) async {
    when(() => listenersApi.setOnline(true)).thenAnswer(
      (_) async => const ListenerStatusResult(isOnline: true, isBusy: false),
    );

    await pumpReady(tester, _bothRoleUser);
    await tester.tap(find.byKey(const Key('profile_role_listener')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('profile_availability_switch')));
    await tester.pump();
    await tester.pump();

    verify(() => listenersApi.setOnline(true)).called(1);
  });

  testWidgets('tapping settings navigates to the settings screen', (tester) async {
    await pumpReady(tester, _caller);

    await tester.tap(find.byKey(const Key('profile_settings_row')));
    await tester.pumpAndSettle();

    expect(find.text('settings screen'), findsOneWidget);
  });

  testWidgets('tapping edit navigates to the edit screen', (tester) async {
    await pumpReady(tester, _caller);

    await tester.tap(find.byKey(const Key('profile_edit_button')));
    await tester.pumpAndSettle();

    expect(find.text('edit screen'), findsOneWidget);
  });

  testWidgets('tapping the coin ledger row navigates there', (tester) async {
    await pumpReady(tester, _caller);

    await tester.tap(find.byKey(const Key('profile_coin_ledger_row')));
    await tester.pumpAndSettle();

    expect(find.text('coin ledger screen'), findsOneWidget);
  });

  testWidgets('tapping the earnings ledger row navigates there', (tester) async {
    await pumpReady(tester, _bothRoleUser);
    await tester.tap(find.byKey(const Key('profile_role_listener')));
    await tester.pump();
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const Key('profile_earnings_ledger_row')),
      200,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile_earnings_ledger_row')));
    await tester.pumpAndSettle();

    expect(find.text('earnings ledger screen'), findsOneWidget);
  });
}
