import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/listener_profile/listener_profile_screen.dart';
import 'package:moco/shared/models/listener.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

const _detail = ListenerDetail(
  id: 7,
  displayName: 'Priya',
  bio: 'Here to listen, any time.',
  languages: ['hi', 'en'],
  audioRate: 6,
  videoRate: 12,
  isOnline: true,
  rating: 4.8,
  ratingCount: 132,
  totalCalls: 214,
);

void main() {
  late _MockListenersApi api;

  setUpAll(() => registerFallbackValue(const DiscoveryFilters()));

  late List<Override> base;

  setUp(() async {
    api = _MockListenersApi();
    base = await baseOverrides();
    when(
      () => api.discover(
        filters: any(named: 'filters'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const DiscoveryPage());
  });

  Widget subject({int? id = 7}) => wrapWidget(
    ListenerProfileScreen(listenerId: id),
    overrides: [...base, listenersApiProvider.overrideWithValue(api)],
  );

  testWidgets('renders the listener from the backend', (tester) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    // The compact header carries the same name, so target the hero explicitly.
    expect(find.byKey(const Key('profile_hero_name')), findsOneWidget);
    expect(find.text('Here to listen, any time.'), findsOneWidget);
    expect(find.text('Available now'), findsOneWidget);
    expect(find.text('4.8'), findsOneWidget);
  });

  testWidgets('call CTAs show the backend rate, not a client constant', (
    tester,
  ) async {
    when(() => api.byId(7)).thenAnswer(
      // A listener on a custom rate: the UI must follow the server.
      (_) async => _detail.copyWith(audioRate: 9, videoRate: 18),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.textContaining('9/min'), findsOneWidget);
    expect(find.textContaining('18/min'), findsOneWidget);
  });

  testWidgets('favourite, follow and chat are disabled in Phase 1', (
    tester,
  ) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    // No backend endpoint exists, so these must not appear functional.
    for (final icon in [
      Icons.favorite_border_rounded,
      Icons.person_add_alt_1_outlined,
      Icons.chat_bubble_outline_rounded,
    ]) {
      final button = tester.widget<InkWell>(
        find
            .ancestor(of: find.byIcon(icon), matching: find.byType(InkWell))
            .first,
      );
      expect(button.onTap, isNull, reason: '$icon must be disabled');
    }
  });

  testWidgets('an offline listener cannot be called', (tester) async {
    when(() => api.byId(7))
        .thenAnswer((_) async => _detail.copyWith(isOnline: false));

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('a busy listener is shown as on another call', (tester) async {
    when(() => api.byId(7))
        .thenAnswer((_) async => _detail.copyWith(isBusy: true));

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.text('On another call'), findsOneWidget);
  });

  testWidgets('shows an error state with retry when the load fails', (
    tester,
  ) async {
    when(() => api.byId(7)).thenThrow(
      const ApiException(
        kind: ApiErrorKind.network,
        message: "You're offline. Reconnect and try again.",
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('listener_profile_error')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a malformed deep link does not crash', (tester) async {
    await tester.pumpWidget(subject(id: null));
    await tester.pumpAndSettle();

    expect(find.text('Listener not found'), findsOneWidget);
    verifyNever(() => api.byId(any()));
  });

  testWidgets('content tabs render honest empty states', (tester) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    // The screen nests a horizontal tab strip inside the vertical list, so
    // scrollUntilVisible cannot pick a scrollable on its own.
    final postsChip = find.byKey(const Key('profile_tab_chip_posts'));
    await tester.ensureVisible(postsChip);
    await tester.pumpAndSettle();

    await tester.tap(postsChip);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile_tab_posts')), findsOneWidget);
    expect(find.textContaining('later phase'), findsWidgets);
  });
}
