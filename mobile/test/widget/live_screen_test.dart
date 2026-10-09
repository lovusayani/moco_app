import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/api/live_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/platform/platform_capabilities.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/routing/app_router.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/live/live_controller.dart';
import 'package:moco/shared/models/feed.dart';
import 'package:moco/shared/models/listener.dart';
import 'package:moco/shared/models/live.dart';
import 'package:moco/shared/models/user.dart';

import '../support/harness.dart';

/// Moco Live on web: top-bar navigation, the 18+ gate, the states, and that
/// the admin's layout / card-field / tap settings drive what renders. Driven
/// through the real router with a fake LiveApi (no provider is ever called).

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockFeedApi extends Mock implements FeedApi {}

class _MockChatApi extends Mock implements ChatApi {}

class _FakeLiveApi implements LiveApi {
  _FakeLiveApi({required this.configJson, this.list = const []});

  Map<String, dynamic> configJson;
  List<LiveModel> list;
  bool available = true;
  ApiException? modelsError;
  Completer<void>? holdModels;
  final calls = <String>[];

  @override
  Future<LiveConfig> config() async {
    calls.add('config');
    return LiveConfig.fromJson(configJson);
  }

  @override
  Future<LiveModelsPage> models({required int limit, int offset = 0}) async {
    calls.add('models:$limit:$offset');
    await holdModels?.future;
    if (modelsError != null) throw modelsError!;
    final page = list.skip(offset).take(limit).toList();
    return LiveModelsPage(
      available: available,
      models: page,
      limit: limit,
      offset: offset,
    );
  }
}

const _web = PlatformCapabilities(isWeb: true);
const _user = MocoUser(
  id: 1,
  phone: '+919876543210',
  displayName: 'Rahul',
  coinBalance: 50,
);

Map<String, dynamic> config({
  bool enabled = true,
  bool gate = true,
  int pageSize = 24,
  String preset = 'grid',
  Map<String, int> columns = const {'mobile': 2, 'tablet': 3, 'desktop': 4},
  Map<String, bool> card = const {},
  String click = 'internal_player',
}) => {
  'enabled': enabled,
  'requireAgeConfirmation': gate,
  'pageSize': pageSize,
  'layout': {
    'preset': preset,
    'columns': columns,
    'aspect': 'portrait',
    'density': 'comfortable',
    'radius': 'medium',
  },
  'card': card,
  'sort': 'default',
  'clickBehavior': click,
  'player': enabled
      ? {
          'type': 'stripchat-player',
          'userId': 'aff',
          'strict': 1,
          'autoplay': 'all',
          'scriptUrl': null,
        }
      : null,
};

LiveModel model(int i, {String? destination}) => LiveModel(
  id: i,
  username: 'Model_$i',
  country: 'co',
  languages: const ['es', 'en'],
  tags: const ['girls/latin'],
  viewers: 100 + i,
  favorites: 900,
  isHd: i.isEven,
  goal: const LiveGoal(message: 'Show', needed: 100, earned: 40),
  destinationUrl: destination,
);

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
    _FakeLiveApi live, {
    bool ageConfirmed = false,
    Size size = const Size(390, 844),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      // Test-font overflow in fixed nav slots and network images (no HTTP in
      // tests) are not what this file checks.
      final s = details.exceptionAsString();
      if (s.contains('overflowed') ||
          s.contains('HTTP request failed') ||
          s.contains('NetworkImage')) {
        return;
      }
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
          platformCapabilitiesProvider.overrideWithValue(_web),
          listenersApiProvider.overrideWithValue(listenersApi),
          feedApiProvider.overrideWithValue(feedApi),
          chatApiProvider.overrideWithValue(chatApi),
          liveApiProvider.overrideWithValue(live),
          if (ageConfirmed)
            liveAgeConfirmedProvider.overrideWith((ref) => true),
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
    // Discover → top bar → Live, as a person does.
    await tester.tap(find.byKey(const Key('nav_live')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('topbar_live')));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  testWidgets('top bar Live opens the Live screen and stays highlighted', (
    tester,
  ) async {
    final live = _FakeLiveApi(configJson: config(), list: [model(1)]);
    await pumpApp(tester, live, ageConfirmed: true);

    expect(find.byKey(const Key('live_grid')), findsOneWidget);
    final dot = tester.getCenter(find.byKey(const Key('topbar_indicator')));
    expect(
      tester.getRect(find.byKey(const Key('topbar_live'))).contains(dot),
      isTrue,
    );
    expect(find.byKey(const Key('live_empty')), findsNothing);
  });

  group('18+ gate', () {
    testWidgets('nothing loads until confirmed; confirming loads models', (
      tester,
    ) async {
      final live = _FakeLiveApi(
        configJson: config(),
        list: [model(1), model(2)],
      );
      await pumpApp(tester, live);

      expect(find.byKey(const Key('live_age_gate')), findsOneWidget);
      expect(
        live.calls.where((c) => c.startsWith('models')),
        isEmpty,
        reason: 'no models before confirming',
      );

      await tester.tap(find.byKey(const Key('live_age_confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_age_gate')), findsNothing);
      expect(find.byKey(const Key('live_card_Model_1')), findsOneWidget);
    });

    testWidgets('Go back leaves Live without loading anything', (tester) async {
      final live = _FakeLiveApi(configJson: config(), list: [model(1)]);
      await pumpApp(tester, live);
      await tester.tap(find.byKey(const Key('live_age_cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discovery_web_header')), findsOneWidget);
      expect(live.calls.where((c) => c.startsWith('models')), isEmpty);
    });

    testWidgets('no gate when the admin turned it off', (tester) async {
      final live = _FakeLiveApi(
        configJson: config(gate: false),
        list: [model(1)],
      );
      await pumpApp(tester, live);
      expect(find.byKey(const Key('live_age_gate')), findsNothing);
      expect(find.byKey(const Key('live_card_Model_1')), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets(
      'disabled Live shows "Live is unavailable" and loads no models',
      (tester) async {
        final live = _FakeLiveApi(configJson: config(enabled: false));
        await pumpApp(tester, live);
        expect(find.byKey(const Key('live_unavailable')), findsOneWidget);
        expect(find.byKey(const Key('live_age_gate')), findsNothing);
        expect(live.calls.where((c) => c.startsWith('models')), isEmpty);
      },
    );

    testWidgets('loading shows a skeleton', (tester) async {
      final live = _FakeLiveApi(configJson: config(), list: [model(1)])
        ..holdModels = Completer();
      await pumpApp(tester, live, ageConfirmed: true, settle: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('live_skeleton')), findsOneWidget);
      live.holdModels!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_card_Model_1')), findsOneWidget);
    });

    testWidgets('an error offers retry, and retry recovers', (tester) async {
      final live = _FakeLiveApi(configJson: config(), list: [model(1)])
        ..modelsError = const ApiException(
          kind: ApiErrorKind.network,
          message: 'No connection',
        );
      await pumpApp(tester, live, ageConfirmed: true);
      expect(find.byKey(const Key('live_error')), findsOneWidget);

      live.modelsError = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_card_Model_1')), findsOneWidget);
    });

    testWidgets('empty list and provider-unavailable states', (tester) async {
      final live = _FakeLiveApi(configJson: config(), list: const []);
      await pumpApp(tester, live, ageConfirmed: true);
      expect(find.byKey(const Key('live_empty')), findsOneWidget);

      live.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('live_provider_unavailable')),
        findsOneWidget,
      );
    });
  });

  group('admin-driven rendering', () {
    testWidgets('only the card fields the admin enabled are shown', (
      tester,
    ) async {
      final allOff = {
        for (final f in [
          'snapshot',
          'avatar',
          'liveBadge',
          'username',
          'viewers',
          'country',
          'languages',
          'favorites',
          'hdBadge',
          'tags',
          'goal',
        ])
          f: false,
      };
      final live = _FakeLiveApi(
        configJson: config(card: allOff),
        list: [model(2)],
      );
      await pumpApp(tester, live, ageConfirmed: true);
      final card = find.byKey(const Key('live_card_Model_2'));
      for (final k in [
        'live_snapshot',
        'live_avatar',
        'viewers',
        'live_username',
        'live_country',
        'live_meta',
        'hd_badge',
        'live_tags',
        'live_goal',
      ]) {
        expect(
          find.descendant(of: card, matching: find.byKey(Key(k))),
          findsNothing,
          reason: k,
        );
      }
      expect(
        find.descendant(of: card, matching: find.text('LIVE')),
        findsNothing,
      );
    });

    testWidgets('every field shows when enabled', (tester) async {
      final allOn = {
        for (final f in [
          'snapshot',
          'avatar',
          'liveBadge',
          'username',
          'viewers',
          'country',
          'languages',
          'favorites',
          'hdBadge',
          'tags',
          'goal',
        ])
          f: true,
      };
      final live = _FakeLiveApi(
        configJson: config(card: allOn, preset: 'large'),
        list: [model(2)],
      );
      await pumpApp(tester, live, ageConfirmed: true);
      final card = find.byKey(const Key('live_card_Model_2'));
      for (final k in [
        'live_snapshot',
        'live_avatar',
        'viewers',
        'live_username',
        'live_country',
        'live_meta',
        'hd_badge',
        'live_tags',
        'live_goal',
        'live_badge',
      ]) {
        expect(
          find.descendant(of: card, matching: find.byKey(Key(k))),
          findsOneWidget,
          reason: k,
        );
      }
    });

    int columnsOf(WidgetTester tester) {
      final rects = [
        for (final e
            in find
                .byWidgetPredicate(
                  (w) => w.key is Key && '${w.key}'.contains('live_card_'),
                )
                .evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      return rects.where((r) => (r.top - top).abs() < 1).length;
    }

    testWidgets('layout presets and per-device columns', (tester) async {
      final models = [for (var i = 1; i <= 12; i++) model(i)];
      final live = _FakeLiveApi(
        configJson: config(columns: {'mobile': 3, 'tablet': 3, 'desktop': 5}),
        list: models,
      );
      await pumpApp(tester, live, ageConfirmed: true);
      expect(
        columnsOf(tester),
        3,
        reason: 'grid uses the mobile column count at 390px',
      );
    });

    testWidgets('desktop width uses the desktop column count', (tester) async {
      final models = [for (var i = 1; i <= 12; i++) model(i)];
      final live = _FakeLiveApi(
        configJson: config(columns: {'mobile': 2, 'tablet': 3, 'desktop': 5}),
        list: models,
      );
      await pumpApp(
        tester,
        live,
        ageConfirmed: true,
        size: const Size(1400, 900),
      );
      expect(columnsOf(tester), 5);
    });

    testWidgets(
      'compact adds a column; large removes one; mixed leads with a hero',
      (tester) async {
        final models = [for (var i = 1; i <= 12; i++) model(i)];
        final live = _FakeLiveApi(
          configJson: config(preset: 'compact'),
          list: models,
        );
        await pumpApp(tester, live, ageConfirmed: true);
        expect(columnsOf(tester), 3);

        live.configJson = config(preset: 'large');
        await tester.tap(find.byKey(const Key('topbar_call')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topbar_live')));
        await tester.pumpAndSettle();
        expect(columnsOf(tester), 1);

        live.configJson = config(preset: 'mixed');
        await tester.tap(find.byKey(const Key('topbar_call')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topbar_live')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('live_hero')), findsOneWidget);
      },
    );

    testWidgets(
      'renders exactly the backend list, in its order (hidden models never appear)',
      (tester) async {
        // The backend already removed hidden models; the app must not re-add,
        // reorder or filter anything.
        final live = _FakeLiveApi(
          configJson: config(),
          list: [model(3), model(1), model(2)],
        );
        await pumpApp(tester, live, ageConfirmed: true);
        final xs = [
          'Model_3',
          'Model_1',
          'Model_2',
        ].map((n) => tester.getRect(find.byKey(Key('live_card_$n')))).toList();
        expect(xs[0].left < xs[1].left, isTrue);
        expect(xs[2].top > xs[0].top, isTrue);
        expect(find.byKey(const Key('live_card_Hidden')), findsNothing);
      },
    );

    testWidgets('pages with the admin page size via Load more', (tester) async {
      final models = [for (var i = 1; i <= 9; i++) model(i)];
      final live = _FakeLiveApi(configJson: config(pageSize: 6), list: models);
      await pumpApp(tester, live, ageConfirmed: true);
      expect(
        live.calls.where((c) => c.startsWith('models')).first,
        'models:6:0',
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('live_load_more')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.drag(
        find.byKey(const Key('live_scroll')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_load_more')));
      await tester.pumpAndSettle();
      expect(live.calls, contains('models:6:6'));
    });
  });

  group('tap behaviour', () {
    testWidgets('internal player opens the Live player screen', (tester) async {
      final live = _FakeLiveApi(configJson: config(), list: [model(1)]);
      await pumpApp(tester, live, ageConfirmed: true);
      await tester.tap(find.byKey(const Key('live_card_Model_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_player_details')), findsOneWidget);
      expect(
        find.byKey(const Key('live_player_fallback')),
        findsOneWidget,
        reason: 'no player script configured',
      );
      await tester.tap(find.byKey(const Key('live_player_back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_grid')), findsOneWidget);
    });

    testWidgets(
      'player: details overlay hides and shows; back stays reachable',
      (tester) async {
        final live = _FakeLiveApi(configJson: config(), list: [model(1)]);
        await pumpApp(tester, live, ageConfirmed: true);
        await tester.tap(find.byKey(const Key('live_card_Model_1')));
        await tester.pumpAndSettle();

        double opacity() => tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('live_player_details_visibility')),
            )
            .opacity;
        expect(opacity(), 1, reason: 'details visible by default');
        expect(find.text('Model_1'), findsWidgets);
        expect(find.textContaining('watching'), findsOneWidget);
        expect(find.textContaining('External stream'), findsOneWidget);

        await tester.tap(find.byKey(const Key('live_overlay_toggle')));
        await tester.pumpAndSettle();
        expect(opacity(), 0);
        expect(
          find.byKey(const Key('live_player_back')).hitTestable(),
          findsOneWidget,
          reason: 'back stays reachable with details hidden',
        );
        expect(
          find.byKey(const Key('live_player_fallback')),
          findsOneWidget,
          reason: 'hiding details never touches the player',
        );

        await tester.tap(find.byKey(const Key('live_overlay_toggle')));
        await tester.pumpAndSettle();
        expect(opacity(), 1);

        await tester.tap(find.byKey(const Key('live_player_back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('live_grid')), findsOneWidget);
      },
    );

    // The normal player is an embedded, centred 9:16 stage on every screen;
    // only the player's own fullscreen gives it the whole viewport.
    for (final size in const [
      Size(390, 844),
      Size(430, 932),
      Size(820, 1180),
      Size(1440, 900),
    ]) {
      testWidgets(
        'player stage is a centred 9:16 on ${size.width.toInt()} px',
        (tester) async {
          final live = _FakeLiveApi(configJson: config(), list: [model(1)]);
          await pumpApp(tester, live, ageConfirmed: true, size: size);
          await tester.tap(find.byKey(const Key('live_card_Model_1')));
          await tester.pumpAndSettle();
          final finder = find.byKey(const Key('live_player_stage'));
          final stage = tester.getSize(finder);
          expect(stage.width / stage.height, closeTo(9 / 16, 0.01));
          expect(stage.height, lessThanOrEqualTo(size.height));
          expect(stage.width, lessThan(size.width));
          final centre = tester.getCenter(finder);
          expect(centre.dx, closeTo(size.width / 2, 1));
          expect(centre.dy, closeTo(size.height / 2, 1));
        },
      );
    }

    testWidgets('provider mode never opens the internal player', (
      tester,
    ) async {
      final live = _FakeLiveApi(
        configJson: config(click: 'provider'),
        list: [model(1, destination: 'https://example.com/x')],
      );
      await pumpApp(tester, live, ageConfirmed: true);
      await tester.tap(find.byKey(const Key('live_card_Model_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_player_details')), findsNothing);
      // Off the web (tests) nothing can be opened, so the user is told.
      expect(
        find.byKey(const Key('live_destination_unavailable')),
        findsOneWidget,
      );
    });
  });

  test('config parsing is tolerant and never hard-codes presentation', () {
    final c = LiveConfig.fromJson({
      'enabled': true,
      'layout': {'preset': 'nope'},
      'pageSize': 999,
    });
    expect(c.layout.preset, LiveLayoutPreset.grid);
    expect(c.pageSize, 60);
    expect(
      c.requireAgeConfirmation,
      isTrue,
      reason: 'only an explicit false turns the gate off',
    );
    expect(LiveColumns.fromJson({'mobile': 9}).mobile, 3);
    expect(
      LiveModel.fromJson({'username': 'x', 'snapshotUrl': 'http://insecure'})
          .snapshotUrl,
      isNull,
    );
  });
}
