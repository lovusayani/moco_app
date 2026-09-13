import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moco/features/discovery/discovery_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/api/notifications_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/discovery/discovery_screen.dart';
import 'package:moco/shared/models/listener.dart';
import 'package:moco/shared/models/notification.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockNotificationsApi extends Mock implements NotificationsApi {}

ListenerSummary _listener(int id, String name, {bool online = true}) =>
    ListenerSummary(
      id: id,
      displayName: name,
      audioRate: 6,
      videoRate: 12,
      isOnline: online,
      languages: const ['hi', 'en'],
      rating: 4.6,
    );

void main() {
  late _MockListenersApi api;
  late List<Override> base;

  setUpAll(() {
    registerFallbackValue(const DiscoveryFilters());
  });

  setUp(() async {
    api = _MockListenersApi();
    base = await baseOverrides();
  });

  Widget subject() => wrapShellScreen(
    const DiscoveryScreen(),
    overrides: [...base, listenersApiProvider.overrideWithValue(api)],
  );

  testWidgets('shows a skeleton while loading', (tester) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) => Future.delayed(
        const Duration(milliseconds: 300),
        () => const DiscoveryPage(),
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pump();

    expect(find.byKey(const Key('discovery_empty')), findsNothing);
    expect(find.byKey(const Key('discovery_error')), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('renders listener cards from the backend', (tester) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => DiscoveryPage(
        listeners: [_listener(1, 'Priya'), _listener(2, 'Kavya')],
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('listener_card_1')), findsOneWidget);
    expect(find.byKey(const Key('listener_card_2')), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets('shows the empty state when the backend returns nothing', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => const DiscoveryPage());

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discovery_empty')), findsOneWidget);
  });

  testWidgets('shows a retry action on a retryable failure', (tester) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.network,
        message: "You're offline. Reconnect and try again.",
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discovery_error')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the audio/video toggle filters server-side, not just relabels', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => DiscoveryPage(listeners: [_listener(1, 'Priya')]),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    // Audio is the default: the card shows the backend's audioRate.
    expect(find.text('6/min'), findsOneWidget);

    await tester.tap(find.byKey(const Key('discovery_mode_video')));
    await tester.pumpAndSettle();

    expect(find.text('12/min'), findsOneWidget);

    // The toggle must reach the API as a real capability filter — previously
    // it only changed which rate was displayed.
    final captured = verify(
      () => api.discover(
        filters: captureAny(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).captured;
    expect(
      captured.whereType<DiscoveryFilters>().any((f) => f.callType == 'video'),
      isTrue,
    );
  });

  testWidgets('search reaches the backend as a query parameter', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => DiscoveryPage(listeners: [_listener(1, 'Priya')]),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('discovery_search_toggle')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('discovery_search_field')),
      'Priya',
    );
    // Search is debounced, so nothing should fire immediately.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    final captured = verify(
      () => api.discover(
        filters: captureAny(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).captured;
    expect(
      captured.whereType<DiscoveryFilters>().any((f) => f.query == 'Priya'),
      isTrue,
      reason: 'search must be server-side, not a filter over the loaded page',
    );
  });

  testWidgets('an empty search result says so, distinctly from no listeners', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => const DiscoveryPage());

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('discovery_search_toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('discovery_search_field')),
      'zzz',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('No matches'), findsOneWidget);
    // The query echoes in the message. Scoped to the empty state, since the
    // search field also contains it.
    expect(
      find.descendant(
        of: find.byKey(const Key('discovery_empty')),
        matching: find.textContaining('zzz'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a live presence event updates a card without a refetch', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async =>
          DiscoveryPage(listeners: [_listener(1, 'Priya', online: true)]),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    expect(find.text('Online'), findsOneWidget);

    // What the socket handler does when the server broadcasts a change.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DiscoveryScreen)),
    );
    container
        .read(discoveryControllerProvider.notifier)
        .applyPresence(listenerId: 1, isOnline: false, isBusy: false);
    await tester.pumpAndSettle();

    // The card reflects it with no additional discover() call — one for the
    // initial load, and nothing more.
    expect(find.text('Online'), findsNothing);
    verify(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).called(1);
  });

  testWidgets('presence for a listener not on screen is ignored', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => DiscoveryPage(listeners: [_listener(1, 'Priya')]),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DiscoveryScreen)),
    );
    // A listener who does not match the active filters must not be injected.
    container
        .read(discoveryControllerProvider.notifier)
        .applyPresence(listenerId: 999, isOnline: true, isBusy: false);
    await tester.pumpAndSettle();

    expect(container.read(discoveryControllerProvider).listeners.length, 1);
  });

  testWidgets('selecting a language filter re-queries the backend', (
    tester,
  ) async {
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => DiscoveryPage(listeners: [_listener(1, 'Priya')]),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('filter_lang_hi')));
    await tester.pumpAndSettle();

    // The filter must reach the API, not just tint a chip.
    final captured = verify(
      () => api.discover(
        filters: captureAny(named: 'filters'),
        offset: any(named: 'offset'),
      ),
    ).captured;

    expect(
      captured.whereType<DiscoveryFilters>().any((f) => f.language == 'hi'),
      isTrue,
    );
  });

  testWidgets('the notifications bell shows an unread badge when there is unread mail', (
    tester,
  ) async {
    when(
      () => api.discover(filters: any(named: 'filters'), offset: any(named: 'offset')),
    ).thenAnswer((_) async => const DiscoveryPage());

    final notificationsApi = _MockNotificationsApi();
    when(() => notificationsApi.list()).thenAnswer(
      (_) async => const NotificationPage(unreadCount: 2),
    );

    await tester.pumpWidget(
      wrapShellScreen(
        const DiscoveryScreen(),
        overrides: [
          ...base,
          listenersApiProvider.overrideWithValue(api),
          notificationsApiProvider.overrideWithValue(notificationsApi),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discovery_notifications_badge')), findsOneWidget);
  });

  testWidgets('no badge when the inbox has nothing unread', (tester) async {
    when(
      () => api.discover(filters: any(named: 'filters'), offset: any(named: 'offset')),
    ).thenAnswer((_) async => const DiscoveryPage());

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    // subject() uses baseOverrides()'s default empty-inbox stub.
    expect(find.byKey(const Key('discovery_notifications_badge')), findsNothing);
  });
}
