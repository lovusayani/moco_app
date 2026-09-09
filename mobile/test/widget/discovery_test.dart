import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/discovery/discovery_screen.dart';
import 'package:moco/shared/models/listener.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

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

  testWidgets('the audio/video toggle switches the displayed rate', (
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
}
