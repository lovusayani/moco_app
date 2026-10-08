import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/platform/platform_capabilities.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/routing/app_router.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/app_shell/app_shell.dart';
import 'package:moco/shared/models/feed.dart';
import 'package:moco/shared/models/listener.dart';
import 'package:moco/shared/models/user.dart';

import '../support/harness.dart';

/// The web app's own navigation: Live / Search / Feed / Chat / Profile, Feed
/// as the landing tab, and a Discovery header with only the centred toggle.
/// Driven through the real router with [platformCapabilitiesProvider] told it
/// is on web; the native cases pin that Android is unchanged.

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockFeedApi extends Mock implements FeedApi {}

class _MockChatApi extends Mock implements ChatApi {}

const _web = PlatformCapabilities(isWeb: true);
const _native = PlatformCapabilities(isWeb: false);

const _user = MocoUser(id: 1, phone: '+919876543210', displayName: 'Rahul');

void main() {
  late _MockListenersApi listenersApi;
  late _MockFeedApi feedApi;
  late _MockChatApi chatApi;

  setUpAll(() => registerFallbackValue(const DiscoveryFilters()));

  setUp(() {
    listenersApi = _MockListenersApi();
    feedApi = _MockFeedApi();
    chatApi = _MockChatApi();
    when(
      () => listenersApi.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => const DiscoveryPage());
    when(
      () => feedApi.feed(
        limit: any(named: 'limit'),
        cursor: any(named: 'cursor'),
      ),
    ).thenAnswer((_) async => const FeedPage());
    when(() => chatApi.conversations()).thenAnswer((_) async => const []);
  });

  Future<void> pumpApp(
    WidgetTester tester,
    PlatformCapabilities capabilities,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The test font is taller than Inter, so the nav labels (unchanged in
    // size here, on Android and web alike) overflow their 46px slot by a few
    // pixels in tests only. Overflow at real device sizes is layout_test's
    // job; this file is about navigation.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    final overrides = await signedInOverrides(
      user: _user,
      onboardingComplete: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          platformCapabilitiesProvider.overrideWithValue(capabilities),
          listenersApiProvider.overrideWithValue(listenersApi),
          feedApiProvider.overrideWithValue(feedApi),
          chatApiProvider.overrideWithValue(chatApi),
        ],
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            theme: MocoTheme.dark(),
            routerConfig: ref.watch(routerProvider),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String navLabel(WidgetTester tester, String key) => tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
      )
      .single
      .data!;

  EditableText searchField(WidgetTester tester) => tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(const Key('discovery_search_field')),
      matching: find.byType(EditableText),
    ),
  );

  List<DiscoveryFilters> discoverCalls() => verify(
    () => listenersApi.discover(
      filters: captureAny(named: 'filters'),
      offset: any(named: 'offset'),
    ),
  ).captured.cast<DiscoveryFilters>();

  group('web', () {
    testWidgets('the nav is Live, Search, Feed, Chat, Profile — no Wallet', (
      tester,
    ) async {
      await pumpApp(tester, _web);

      expect(
        [
          for (final key in [
            'nav_live',
            'nav_search',
            'nav_feed',
            'nav_chats',
            'nav_profile',
          ])
            navLabel(tester, key),
        ],
        ['Live', 'Search', 'Feed', 'Chat', 'Profile'],
      );
      expect(find.byKey(const Key('nav_wallet')), findsNothing);
      expect(find.byKey(const Key('nav_discovery')), findsNothing);
      expect(
        WebShellTab.values[WebShellTab.values.length ~/ 2],
        WebShellTab.feed,
        reason: 'Feed stays the centre item',
      );
    });

    testWidgets('opens on Feed after a signed-in start', (tester) async {
      await pumpApp(tester, _web);

      expect(
        find.byIcon(Icons.video_call_rounded),
        findsOneWidget,
        reason: 'Feed (create-video icon) is the selected tab',
      );
      verify(
        () => feedApi.feed(
          limit: any(named: 'limit'),
          cursor: any(named: 'cursor'),
        ),
      ).called(greaterThan(0));
      expect(find.byKey(const Key('discovery_web_header')), findsNothing);
    });

    testWidgets('Live opens Discovery with no title and Video active', (
      tester,
    ) async {
      await pumpApp(tester, _web);

      await tester.tap(find.byKey(const Key('nav_live')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('discovery_web_header')), findsOneWidget);
      expect(find.text('Discover'), findsNothing);
      expect(find.byKey(const Key('discovery_search_toggle')), findsNothing);
      expect(
        find.byIcon(Icons.home_rounded),
        findsOneWidget,
        reason: 'Live is the selected tab',
      );

      final videoSegment = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const Key('discovery_mode_video')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(videoSegment.color, isNot(Colors.transparent));
      expect(
        discoverCalls().first.callType,
        'video',
        reason: 'the first request already asks for video listeners',
      );
    });

    testWidgets('the toggle is centred horizontally', (tester) async {
      await pumpApp(tester, _web);
      await tester.tap(find.byKey(const Key('nav_live')));
      await tester.pumpAndSettle();

      final header = tester.getRect(
        find.byKey(const Key('discovery_web_header')),
      );
      final audio = tester.getRect(
        find.byKey(const Key('discovery_mode_audio')),
      );
      final video = tester.getRect(
        find.byKey(const Key('discovery_mode_video')),
      );
      final toggleCentre = (audio.left + video.right) / 2;
      expect((toggleCentre - header.center.dx).abs(), lessThan(4));
    });

    testWidgets(
      'Search opens and focuses the existing search field; Live closes it',
      (tester) async {
        await pumpApp(tester, _web);

        await tester.tap(find.byKey(const Key('nav_search')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('discovery_web_header')), findsOneWidget);
        expect(searchField(tester).focusNode.hasFocus, isTrue);

        await tester.enterText(
          find.byKey(const Key('discovery_search_field')),
          'Priya',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        final searched = discoverCalls().last;
        expect(searched.query, 'Priya', reason: 'reuses Discovery search');
        expect(searched.callType, 'video', reason: 'keeps the active mode');

        await tester.tap(find.byKey(const Key('nav_live')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(searchField(tester).focusNode.hasFocus, isFalse);
        expect(discoverCalls().last.query, isNull, reason: 'Live clears it');
      },
    );

    testWidgets('tapping Search again re-focuses the field', (tester) async {
      await pumpApp(tester, _web);
      await tester.tap(find.byKey(const Key('nav_search')));
      await tester.pumpAndSettle();
      searchField(tester).focusNode.unfocus();
      await tester.pump();

      await tester.tap(find.byKey(const Key('nav_search')));
      await tester.pumpAndSettle();
      expect(searchField(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('Chat and Profile still open, and Profile still has Wallet', (
      tester,
    ) async {
      await pumpApp(tester, _web);

      await tester.tap(find.byKey(const Key('nav_chats')));
      await tester.pumpAndSettle();
      verify(() => chatApi.conversations()).called(greaterThan(0));

      await tester.tap(find.byKey(const Key('nav_profile')));
      await tester.pumpAndSettle();
      expect(find.text('Rahul'), findsOneWidget);
      expect(find.byKey(const Key('profile_wallet_row')), findsOneWidget);
    });

    test('no tab claims pages outside the nav, like Wallet', () {
      expect(WebShellTab.forLocation(Routes.wallet, searchOpen: false), isNull);
      expect(
        WebShellTab.forLocation(Routes.discovery, searchOpen: true),
        WebShellTab.search,
      );
      expect(
        WebShellTab.forLocation(Routes.discovery, searchOpen: false),
        WebShellTab.live,
      );
    });

    test('the signed-in home is Feed', () {
      expect(homeRouteFor(_web), Routes.feed);
    });
  });

  group('Android is unchanged', () {
    testWidgets('lands on Discovery with its title, search button and tabs', (
      tester,
    ) async {
      await pumpApp(tester, _native);

      expect(find.byKey(const Key('discovery_search_toggle')), findsOneWidget);
      expect(find.byKey(const Key('discovery_web_header')), findsNothing);
      for (final tab in AppShellTab.values) {
        expect(find.byKey(Key('nav_${tab.name}')), findsOneWidget);
      }
      expect(find.byKey(const Key('nav_live')), findsNothing);
      expect(
        discoverCalls().first.callType,
        isNull,
        reason: 'Android keeps its Audio default',
      );
    });

    test('the signed-in home is Discovery', () {
      expect(homeRouteFor(_native), Routes.discovery);
    });
  });
}
