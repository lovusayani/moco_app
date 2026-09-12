import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/media/feed_video_playback.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/feed/feed_screen.dart';
import 'package:moco/shared/models/feed.dart';

import '../support/fake_video_playback.dart';
import '../support/harness.dart';

class _MockFeedApi extends Mock implements FeedApi {}

Post _image(int id, {String? caption, bool isListener = true}) => Post(
  id: id,
  mediaType: PostMediaType.image,
  mediaUrl: 'https://storage.example/$id.jpg',
  caption: caption,
  createdAt: DateTime(2026, 2, 1, 10),
  author: PostAuthor(
    id: 100 + id,
    name: 'Author $id',
    isListener: isListener,
  ),
);

Post _video(int id) => Post(
  id: id,
  mediaType: PostMediaType.video,
  mediaUrl: 'https://storage.example/$id.mp4',
  createdAt: DateTime(2026, 2, 1, 10),
  author: PostAuthor(id: 100 + id, name: 'Author $id', isListener: true),
);

/// Pumps a fixed number of frames rather than settling.
///
/// A feed page holds a CachedNetworkImage whose placeholder spinner animates
/// until the image resolves — and in a test binding the request never
/// resolves, so pumpAndSettle would wait forever on a perfectly healthy
/// screen. Fixed pumps also cover route transitions, which finish well inside
/// this window.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late _MockFeedApi api;
  late RecordingPlaybackFactory playback;
  late List<Override> base;

  setUp(() async {
    api = _MockFeedApi();
    playback = RecordingPlaybackFactory();
    base = await baseOverrides();
  });

  /// The feed lives inside the shell, so it is wrapped in a Scaffold the way
  /// AppShell provides one. A router is present because tapping an author
  /// pushes the existing listener-profile route.
  Widget subject() {
    final router = GoRouter(
      initialLocation: '/feed',
      routes: [
        GoRoute(
          path: '/feed',
          builder: (_, __) => const Scaffold(body: FeedScreen()),
        ),
        GoRoute(
          path: '/listener/:id',
          builder: (_, state) => Scaffold(
            body: Text('listener ${state.pathParameters['id']}'),
          ),
        ),
        GoRoute(
          path: '/feed/compose',
          builder: (_, __) => const Scaffold(body: Text('composer')),
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        ...base,
        feedApiProvider.overrideWithValue(api),
        feedVideoPlaybackFactoryProvider.overrideWithValue(playback.call),
      ],
      child: MaterialApp.router(theme: MocoTheme.dark, routerConfig: router),
    );
  }

  testWidgets('shows a skeleton while the first page loads', (tester) async {
    when(() => api.feed()).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return const FeedPage(posts: []);
    });

    await tester.pumpWidget(subject());
    await tester.pump();

    expect(find.byKey(const Key('feed_loading')), findsOneWidget);
    await settle(tester);
  });

  testWidgets('shows the empty state when there are no posts', (tester) async {
    when(() => api.feed()).thenAnswer((_) async => const FeedPage(posts: []));

    await tester.pumpWidget(subject());
    await settle(tester);

    expect(find.byKey(const Key('feed_empty')), findsOneWidget);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('shows an error with a retry that reloads', (tester) async {
    when(() => api.feed()).thenThrow(
      const ApiException(
        kind: ApiErrorKind.network,
        message: 'No internet connection',
      ),
    );

    await tester.pumpWidget(subject());
    await settle(tester);

    expect(find.byKey(const Key('feed_error')), findsOneWidget);
    expect(find.text('No internet connection'), findsOneWidget);

    when(() => api.feed()).thenAnswer((_) async => FeedPage(posts: [_image(1)]));
    await tester.tap(find.text('Try again'));
    await settle(tester);

    expect(find.byKey(const Key('feed_error')), findsNothing);
    expect(find.text('Author 1'), findsOneWidget);
  });

  testWidgets('renders an image post with its author and caption', (tester) async {
    when(() => api.feed()).thenAnswer(
      (_) async => FeedPage(posts: [_image(1, caption: 'sunset today')]),
    );

    await tester.pumpWidget(subject());
    await settle(tester);

    expect(find.byKey(const Key('feed_pager')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed_image_1')), findsOneWidget);
    expect(find.text('Author 1'), findsOneWidget);
    expect(find.byKey(const Key('feed_post_caption')), findsOneWidget);
    expect(find.text('sunset today'), findsOneWidget);
    // No video on an image post.
    expect(playback.count, 0);
  });

  testWidgets('a post with no caption renders without an empty line', (tester) async {
    when(() => api.feed()).thenAnswer((_) async => FeedPage(posts: [_image(1)]));

    await tester.pumpWidget(subject());
    await settle(tester);

    expect(find.byKey(const Key('feed_post_caption')), findsNothing);
  });

  testWidgets('a post whose media URL could not be minted says so', (tester) async {
    when(() => api.feed()).thenAnswer(
      (_) async => FeedPage(
        posts: [
          Post(
            id: 1,
            mediaType: PostMediaType.image,
            mediaUrl: null,
            createdAt: DateTime(2026, 2, 1),
            author: const PostAuthor(id: 7, name: 'Priya'),
          ),
        ],
      ),
    );

    await tester.pumpWidget(subject());
    await settle(tester);

    expect(find.byKey(const Key('feed_media_missing')), findsOneWidget);
    // The post still renders; the feed degrades rather than hiding it.
    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets('the first video post plays and later ones do not', (tester) async {
    when(() => api.feed()).thenAnswer(
      (_) async => FeedPage(posts: [_video(3), _video(2), _video(1)]),
    );

    await tester.pumpWidget(subject());
    await settle(tester);

    // Exactly one controller exists, for the current page.
    expect(playback.count, 1);
    expect(playback.last.url, 'https://storage.example/3.mp4');
    expect(playback.last.playCount, 1);
  });

  testWidgets('swiping to the next video disposes the previous one', (tester) async {
    when(() => api.feed()).thenAnswer(
      (_) async => FeedPage(posts: [_video(3), _video(2)]),
    );

    await tester.pumpWidget(subject());
    await settle(tester);
    final first = playback.last;

    await tester.fling(
      find.byKey(const Key('feed_pager')),
      const Offset(0, -600),
      1200,
    );
    await settle(tester);

    expect(first.disposeCount, 1, reason: 'the off-screen video must be released');
    expect(playback.count, 2);
    expect(playback.last.url, 'https://storage.example/2.mp4');
    expect(playback.last.playCount, 1, reason: 'only the new current page plays');
  });

  testWidgets('backgrounding the app stops playback', (tester) async {
    when(() => api.feed()).thenAnswer((_) async => FeedPage(posts: [_video(1)]));

    await tester.pumpWidget(subject());
    await settle(tester);
    final live = playback.last;
    expect(live.disposeCount, 0);

    // Flutter only accepts legal lifecycle transitions, so go through the
    // states a real backgrounding actually passes through.
    for (final phase in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(phase);
    }
    await settle(tester);

    expect(live.disposeCount, 1);

    for (final phase in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(phase);
    }
    await settle(tester);

    expect(playback.count, 2, reason: 'returning to the foreground resumes it');
    expect(playback.last.playCount, 1);
  });

  testWidgets('scrolling near the end requests the next page once', (tester) async {
    when(() => api.feed()).thenAnswer(
      (_) async => FeedPage(
        posts: [_image(5), _image(4), _image(3), _image(2)],
        nextCursor: 2,
      ),
    );
    when(() => api.feed(cursor: 2)).thenAnswer(
      (_) async => FeedPage(posts: [_image(1)]),
    );

    await tester.pumpWidget(subject());
    await settle(tester);

    await tester.fling(
      find.byKey(const Key('feed_pager')),
      const Offset(0, -600),
      1200,
    );
    await settle(tester);

    verify(() => api.feed(cursor: 2)).called(1);
    expect(find.byKey(const Key('feed_pager')), findsOneWidget);
  });

  testWidgets('tapping a listener author opens the existing profile route', (tester) async {
    when(() => api.feed()).thenAnswer((_) async => FeedPage(posts: [_image(1)]));

    await tester.pumpWidget(subject());
    await settle(tester);

    await tester.tap(find.byKey(const Key('feed_author_101')));
    await settle(tester);

    // The existing /listener/:id route, not a duplicate profile screen.
    expect(find.text('listener 101'), findsOneWidget);
  });

  testWidgets('a non-listener author is not a link', (tester) async {
    when(() => api.feed()).thenAnswer(
      (_) async => FeedPage(posts: [_image(1, isListener: false)]),
    );

    await tester.pumpWidget(subject());
    await settle(tester);

    // No profile screen exists for a non-listener, so the name must not be a
    // control that goes nowhere.
    expect(find.byKey(const Key('feed_author_101')), findsNothing);
    expect(find.text('Author 1'), findsOneWidget);
  });

  testWidgets('the compose button opens the composer', (tester) async {
    when(() => api.feed()).thenAnswer((_) async => const FeedPage(posts: []));

    await tester.pumpWidget(subject());
    await settle(tester);

    await tester.tap(find.byKey(const Key('feed_compose_button')));
    await settle(tester);

    expect(find.text('composer'), findsOneWidget);
  });
}
