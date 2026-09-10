import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/widgets/moco_avatar.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/listener_profile/listener_profile_screen.dart';
import 'package:moco/shared/models/listener.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

const _detail = ListenerDetail(
  id: 7,
  verified: true,
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

  testWidgets('favouriting calls the backend and flips the button', (
    tester,
  ) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);
    when(
      () => api.setRelation(
        listenerId: any(named: 'listenerId'),
        kind: any(named: 'kind'),
        active: any(named: 'active'),
      ),
    ).thenAnswer(
      (_) async => const RelationResult(
        listenerId: 7,
        kind: 'favorite',
        active: true,
        followerCount: 0,
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('action_favorite')));
    await tester.pumpAndSettle();

    verify(() => api.setRelation(listenerId: 7, kind: 'favorite', active: true))
        .called(1);
    // Filled heart means the optimistic update stuck.
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  testWidgets('following increments the visible follower count', (
    tester,
  ) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);
    when(
      () => api.setRelation(
        listenerId: any(named: 'listenerId'),
        kind: any(named: 'kind'),
        active: any(named: 'active'),
      ),
    ).thenAnswer(
      (_) async => const RelationResult(
        listenerId: 7,
        kind: 'follow',
        active: true,
        followerCount: 1,
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();
    expect(find.text('0'), findsWidgets);

    await tester.tap(find.byKey(const Key('action_follow')));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsWidgets);
    expect(find.text('follower'), findsOneWidget);
  });

  testWidgets('a failed favourite rolls back rather than sticking', (
    tester,
  ) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);
    when(
      () => api.setRelation(
        listenerId: any(named: 'listenerId'),
        kind: any(named: 'kind'),
        active: any(named: 'active'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.network,
        message: "You're offline. Reconnect and try again.",
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('action_favorite')));
    await tester.pumpAndSettle();

    // Back to the outline heart: nothing was persisted, so nothing may look
    // persisted. A stuck optimistic update would show a favourite that the
    // server never recorded.
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    expect(find.textContaining("offline"), findsOneWidget);
  });

  testWidgets('a failed follow rolls the count back too', (tester) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);
    when(
      () => api.setRelation(
        listenerId: any(named: 'listenerId'),
        kind: any(named: 'kind'),
        active: any(named: 'active'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.server,
        message: 'Moco is having trouble right now.',
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('action_follow')));
    await tester.pumpAndSettle();

    expect(find.text('followers'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('an already-favourited listener renders as favourited', (
    tester,
  ) async {
    when(() => api.byId(7))
        .thenAnswer((_) async => _detail.copyWith(isFavorited: true));

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  testWidgets('chat stays disabled until Phase 3', (tester) async {
    when(() => api.byId(7)).thenAnswer((_) async => _detail);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    final chat = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.byIcon(Icons.chat_bubble_outline_rounded),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(chat.onTap, isNull);
  });

  testWidgets('only the call types a listener accepts are offered', (
    tester,
  ) async {
    when(() => api.byId(7)).thenAnswer(
      (_) async => _detail.copyWith(acceptsAudio: true, acceptsVideo: false),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cta_audio_call')), findsOneWidget);
    // Offering a video call to someone who does not take them would fail at
    // the point of calling.
    expect(find.byKey(const Key('cta_video_call')), findsNothing);
  });

  testWidgets('an unverified listener shows no verified badge', (tester) async {
    when(() => api.byId(7))
        .thenAnswer((_) async => _detail.copyWith(verified: false));

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byType(MocoVerifiedBadge), findsNothing);
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

    // The screen nests a horizontal tab strip inside the vertical list, so the
    // outer scrollable has to be named explicitly. ensureVisible alone can park
    // the chip underneath the compact header, which then swallows the tap.
    final postsChip = find.byKey(const Key('profile_tab_chip_posts'));
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(postsChip, 40, scrollable: scrollable);
    await tester.pumpAndSettle();

    // The sticky compact header legitimately absorbs taps in its own area, so
    // nudge the chip clear of it before tapping rather than tapping through it.
    final headerBottom = tester.getRect(find.byType(ListView).first).top + 140;
    var centre = tester.getCenter(postsChip);
    if (centre.dy < headerBottom) {
      await tester.drag(scrollable, Offset(0, headerBottom - centre.dy + 20));
      await tester.pumpAndSettle();
      centre = tester.getCenter(postsChip);
    }

    await tester.tap(postsChip, warnIfMissed: true);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile_tab_posts')), findsOneWidget);
    expect(find.textContaining('later phase'), findsWidgets);
  });
}
