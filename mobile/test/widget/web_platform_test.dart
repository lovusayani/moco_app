import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/calls_api.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/api/payouts_api.dart';
import 'package:moco/core/api/wallet_api.dart';
import 'package:moco/core/calling/call_controller.dart';
import 'package:moco/core/payments/purchase_provider.dart';
import 'package:moco/core/platform/platform_capabilities.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/routing/pop_or_go.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/core/widgets/moco_app_frame.dart';
import 'package:moco/features/chat_thread/chat_thread_screen.dart';
import 'package:moco/features/listener_profile/listener_profile_screen.dart';
import 'package:moco/features/profile/profile_screen.dart';
import 'package:moco/features/wallet/wallet_controller.dart';
import 'package:moco/features/wallet/wallet_screen.dart';
import 'package:moco/shared/models/app_config.dart';
import 'package:moco/shared/models/call.dart';
import 'package:moco/shared/models/chat.dart';
import 'package:moco/shared/models/earnings.dart';
import 'package:moco/shared/models/listener.dart';
import 'package:moco/shared/models/user.dart';
import 'package:moco/shared/models/wallet.dart';

import '../support/harness.dart';

/// The web build's honest-degradation rules, exercised by overriding
/// [platformCapabilitiesProvider] — the same screens, told they are on web.

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockCallsApi extends Mock implements CallsApi {}

class _MockChatApi extends Mock implements ChatApi {}

class _MockPayoutsApi extends Mock implements PayoutsApi {}

class _MockWalletApi extends Mock implements WalletApi {}

const _web = PlatformCapabilities(isWeb: true);

const _listener = ListenerDetail(
  id: 7,
  verified: true,
  displayName: 'Priya',
  audioRate: 6,
  videoRate: 12,
  isOnline: true,
);

void main() {
  setUpAll(() {
    registerFallbackValue(const DiscoveryFilters());
    registerFallbackValue(CallType.audio);
  });

  group('calling on web', () {
    late _MockListenersApi listenersApi;
    late _MockCallsApi callsApi;
    late List<Override> base;

    setUp(() async {
      listenersApi = _MockListenersApi();
      callsApi = _MockCallsApi();
      base = await baseOverrides();
      when(() => listenersApi.byId(7)).thenAnswer((_) async => _listener);
    });

    Widget subject() => wrapWidget(
      const ListenerProfileScreen(listenerId: 7),
      overrides: [
        ...base,
        listenersApiProvider.overrideWithValue(listenersApi),
        callsApiProvider.overrideWithValue(callsApi),
        platformCapabilitiesProvider.overrideWithValue(_web),
      ],
    );

    testWidgets('a call CTA explains calls are app-only and never initiates one', (tester) async {
      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();

      // The rates are still shown, with the platform note up front.
      expect(find.byKey(const Key('calling_unavailable_note')), findsOneWidget);

      await tester.tap(find.byKey(const Key('cta_audio_call')));
      await tester.pump();

      expect(find.byKey(const Key('calling_unavailable_snackbar')), findsOneWidget);
      expect(find.text(PlatformCapabilities.callingUnavailableMessage), findsOneWidget);
      verifyNever(
        () => callsApi.initiate(listenerId: any(named: 'listenerId'), type: any(named: 'type')),
      );
    });

    testWidgets('native builds show no web note', (tester) async {
      await tester.pumpWidget(
        wrapWidget(
          const ListenerProfileScreen(listenerId: 7),
          overrides: [
            ...base,
            listenersApiProvider.overrideWithValue(listenersApi),
            callsApiProvider.overrideWithValue(callsApi),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calling_unavailable_note')), findsNothing);
    });
  });

  group('listener availability on web', () {
    const onlineCapable = MocoUser(
      id: 2,
      phone: '+919800000002',
      displayName: 'Priya',
      role: 'both',
      listener: ListenerState(isOnline: false, kycStatus: 'approved'),
    );

    late _MockListenersApi listenersApi;
    late _MockPayoutsApi payoutsApi;

    setUp(() {
      listenersApi = _MockListenersApi();
      payoutsApi = _MockPayoutsApi();
      when(() => payoutsApi.earnings()).thenAnswer(
        (_) async => const EarningsSummary(
          balance: 0,
          lifetime: 0,
          today: 0,
          thisMonth: 0,
          totalCalls: 0,
          rating: 0,
          minWithdrawal: 100,
          canWithdraw: false,
        ),
      );
    });

    testWidgets('an offline listener cannot go online from the web', (tester) async {
      final router = GoRouter(
        initialLocation: '/profile',
        routes: [
          GoRoute(path: '/profile', builder: (_, __) => const Scaffold(body: ProfileScreen())),
        ],
      );
      final overrides = await signedInOverrides(user: onlineCapable);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides,
            listenersApiProvider.overrideWithValue(listenersApi),
            payoutsApiProvider.overrideWithValue(payoutsApi),
            platformCapabilitiesProvider.overrideWithValue(_web),
          ],
          child: MaterialApp.router(theme: MocoTheme.dark(), routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('profile_role_listener')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('profile_go_online_unavailable')), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile_availability_switch')));
      await tester.pump();

      verifyNever(() => listenersApi.setOnline(any()));
    });
  });

  group('purchases on web', () {
    test('the unsupported provider is never available and refuses to purchase', () async {
      const provider = UnsupportedPlatformPurchaseProvider(
        PlatformCapabilities.purchasesUnavailableMessage,
      );

      expect(provider.isAvailable, isFalse);
      final result = await provider.purchase(
        const CoinPack(id: 'pack_99', priceInr: 99, coins: 99),
      );
      expect(result.isSuccess, isFalse);
      expect(result.coinBalance, isNull);
    });

    testWidgets('the wallet shows the web reason and offers no purchase', (tester) async {
      final walletApi = _MockWalletApi();
      when(() => walletApi.balance()).thenAnswer(
        (_) async => const WalletBalance(coinBalance: 40, audioMinutes: 6, videoMinutes: 3),
      );
      when(() => walletApi.ledger(limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => const LedgerPage());
      final base = await baseOverrides();

      await tester.pumpWidget(
        wrapShellScreen(
          const WalletScreen(),
          overrides: [
            ...base,
            walletApiProvider.overrideWithValue(walletApi),
            appConfigProvider.overrideWith(
              (ref) async => const AppConfig(
                rates: CallRates(audio: 6, video: 12),
                packs: [CoinPack(id: 'pack_99', priceInr: 99, coins: 99)],
              ),
            ),
            purchaseProviderProvider.overrideWithValue(
              const UnsupportedPlatformPurchaseProvider(
                PlatformCapabilities.purchasesUnavailableMessage,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(PlatformCapabilities.purchasesUnavailableMessage), findsOneWidget);
      verifyNever(() => walletApi.createOrder(any()));
    });
  });

  group('deep link into a chat thread', () {
    testWidgets('the header falls back to the inbox name with no `extra`', (tester) async {
      final api = _MockChatApi();
      when(() => api.conversations()).thenAnswer(
        (_) async => const [Conversation(id: 1, counterpartyId: 7, counterpartyName: 'Priya')],
      );
      when(() => api.messages(7)).thenAnswer((_) async => const MessageHistoryPage(messages: []));
      final base = await baseOverrides();

      await tester.pumpWidget(
        wrapWidget(
          // What the router builds for a refreshed /chat/7: an id, no name.
          const ChatThreadScreen(counterpartyId: 7),
          overrides: [...base, chatApiProvider.overrideWithValue(api)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Priya'), findsOneWidget);
    });
  });

  group('MocoAppFrame', () {
    Future<Size> pumpAt(WidgetTester tester, Size window) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Size seen;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MocoAppFrame(child: child!),
          home: Builder(
            builder: (context) {
              seen = MediaQuery.sizeOf(context);
              return const SizedBox.expand();
            },
          ),
        ),
      );
      return seen;
    }

    testWidgets('is a no-op at phone width', (tester) async {
      final seen = await pumpAt(tester, const Size(390, 844));

      expect(find.byKey(const Key('moco_app_frame')), findsNothing);
      expect(seen.width, 390);
    });

    testWidgets('centres a phone-width column on a desktop window', (tester) async {
      final seen = await pumpAt(tester, const Size(1440, 900));

      expect(find.byKey(const Key('moco_app_frame')), findsOneWidget);
      // Screens lay out against the column, not the window.
      expect(seen.width, 600);
      expect(seen.height, 900);
    });
  });

  group('leaving a deep-linked screen', () {
    GoRouter router(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: '/feed', builder: (_, __) => const Scaffold(body: Text('feed tab'))),
        GoRoute(
          path: '/compose',
          builder: (context, _) => Scaffold(
            appBar: AppBar(leading: deepLinkBackButton(context, '/feed')),
            body: TextButton(
              onPressed: () => popOrGo(context, '/feed'),
              child: const Text('done'),
            ),
          ),
        ),
      ],
    );

    testWidgets('opened by URL, it goes to the fallback instead of a blank pop', (tester) async {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router('/compose')));
      await tester.pumpAndSettle();

      // No page underneath, so the AppBar gets the explicit fallback button.
      expect(find.byKey(const Key('deep_link_back')), findsOneWidget);

      await tester.tap(find.text('done'));
      await tester.pumpAndSettle();

      expect(find.text('feed tab'), findsOneWidget);
    });

    testWidgets('pushed over a page, it pops as before', (tester) async {
      final r = router('/feed');
      await tester.pumpWidget(MaterialApp.router(routerConfig: r));
      await tester.pumpAndSettle();
      r.push('/compose');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('deep_link_back')), findsNothing);

      await tester.tap(find.text('done'));
      await tester.pumpAndSettle();

      expect(find.text('feed tab'), findsOneWidget);
      expect(r.canPop(), isFalse);
    });
  });
}
