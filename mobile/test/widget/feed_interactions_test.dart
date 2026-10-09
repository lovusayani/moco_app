import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/media/feed_video_playback.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/feed/feed_screen.dart';
import 'package:moco/features/feed/share/feed_share.dart';
import 'package:moco/features/feed/share/native_share.dart';
import 'package:moco/features/settings/app_settings_screen.dart';
import 'package:moco/shared/models/feed.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_video_playback.dart';
import '../support/harness.dart';

class _MockFeedApi extends Mock implements FeedApi {}

class _MockListenersApi extends Mock implements ListenersApi {}

Post _image(
  int id, {
  bool canFollow = true,
  bool isFollowing = false,
  int likeCount = 0,
  bool liked = false,
  int commentCount = 0,
  int shareCount = 0,
}) => Post(
  id: id,
  mediaType: PostMediaType.image,
  mediaUrl: 'https://storage.example/$id.jpg',
  createdAt: DateTime(2026, 2, 1, 10),
  author: PostAuthor(
    id: 100 + id,
    name: 'Author $id',
    isListener: true,
    canFollow: canFollow,
    isFollowing: isFollowing,
  ),
  likeCount: likeCount,
  liked: liked,
  commentCount: commentCount,
  shareCount: shareCount,
);

Post _video(int id) => Post(
  id: id,
  mediaType: PostMediaType.video,
  mediaUrl: 'https://storage.example/$id.mp4',
  createdAt: DateTime(2026, 2, 1, 10),
  author: PostAuthor(id: 100 + id, name: 'Author $id', isListener: true),
);

PostComment _comment(int id, String body, {bool canDelete = false}) =>
    PostComment(
      id: id,
      body: body,
      createdAt: DateTime(2026, 2, 1, 10),
      authorId: 1,
      authorName: 'Commenter $id',
      isOwn: canDelete,
      canDelete: canDelete,
    );

/// Fixed pumps rather than settling: a feed image's placeholder spinner
/// never resolves in a test binding.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _likeCount(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('feed_like_count'))).data!;

void main() {
  late _MockFeedApi api;
  late _MockListenersApi listeners;
  late RecordingPlaybackFactory playback;
  late List<Override> base;
  late NativeShareOutcome shareOutcome;
  late int nativeShares;

  setUp(() async {
    api = _MockFeedApi();
    listeners = _MockListenersApi();
    playback = RecordingPlaybackFactory();
    base = await baseOverrides();
    shareOutcome = NativeShareOutcome.unavailable;
    nativeShares = 0;
  });

  /// Saved settings, as the real app reads them at start.
  Future<void> withPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await AppPreferences.create();
    base = [...base, appPreferencesProvider.overrideWithValue(prefs)];
  }

  Widget subject({int? initialPostId}) {
    final router = GoRouter(
      initialLocation: '/feed',
      routes: [
        GoRoute(
          path: '/feed',
          builder: (_, __) =>
              Scaffold(body: FeedScreen(initialPostId: initialPostId)),
        ),
        GoRoute(
          path: '/listener/:id',
          builder: (_, state) =>
              Scaffold(body: Text('listener ${state.pathParameters['id']}')),
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
        listenersApiProvider.overrideWithValue(listeners),
        feedVideoPlaybackFactoryProvider.overrideWithValue(playback.call),
        nativeShareProvider.overrideWithValue(({
          required String title,
          required String text,
          required String url,
        }) async {
          nativeShares += 1;
          return shareOutcome;
        }),
      ],
      child: MaterialApp.router(theme: MocoTheme.dark(), routerConfig: router),
    );
  }

  void feedOf(List<Post> posts, {int? nextCursor}) {
    when(
      () => api.feed(),
    ).thenAnswer((_) async => FeedPage(posts: posts, nextCursor: nextCursor));
  }

  group('action stack', () {
    testWidgets(
      'shows compose, follow, like, comment and share with server counts',
      (tester) async {
        feedOf([_image(1, likeCount: 12, commentCount: 3, shareCount: 1500)]);
        await tester.pumpWidget(subject());
        await settle(tester);

        for (final key in const [
          'feed_compose_button',
          'feed_follow_button',
          'feed_like_button',
          'feed_comment_button',
          'feed_share_button',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget, reason: key);
        }
        expect(_likeCount(tester), '12');
        expect(find.text('3'), findsOneWidget);
        expect(find.text('1.5K'), findsOneWidget);
      },
    );

    testWidgets('compose in the stack opens the composer', (tester) async {
      feedOf([_image(1)]);
      await tester.pumpWidget(subject());
      await settle(tester);
      await tester.tap(find.byKey(const Key('feed_compose_button')));
      await settle(tester);
      expect(find.text('composer'), findsOneWidget);
    });
  });

  group('follow', () {
    testWidgets(
      'follows and unfollows through the existing listener follow API',
      (tester) async {
        feedOf([_image(1)]);
        when(
          () => listeners.setRelation(
            listenerId: 101,
            kind: 'follow',
            active: true,
          ),
        ).thenAnswer(
          (_) async => const RelationResult(
            listenerId: 101,
            kind: 'follow',
            active: true,
            followerCount: 1,
          ),
        );
        when(
          () => listeners.setRelation(
            listenerId: 101,
            kind: 'follow',
            active: false,
          ),
        ).thenAnswer(
          (_) async => const RelationResult(
            listenerId: 101,
            kind: 'follow',
            active: false,
            followerCount: 0,
          ),
        );
        await tester.pumpWidget(subject());
        await settle(tester);
        expect(find.text('Follow'), findsOneWidget);

        await tester.tap(find.byKey(const Key('feed_follow_button')));
        await settle(tester);
        expect(find.text('Following'), findsOneWidget);
        verify(
          () => listeners.setRelation(
            listenerId: 101,
            kind: 'follow',
            active: true,
          ),
        ).called(1);

        await tester.tap(find.byKey(const Key('feed_follow_button')));
        await settle(tester);
        expect(find.text('Follow'), findsOneWidget);
        verify(
          () => listeners.setRelation(
            listenerId: 101,
            kind: 'follow',
            active: false,
          ),
        ).called(1);
      },
    );

    testWidgets('a refused follow is rolled back', (tester) async {
      feedOf([_image(1)]);
      when(
        () => listeners.setRelation(
          listenerId: 101,
          kind: 'follow',
          active: true,
        ),
      ).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      await tester.pumpWidget(subject());
      await settle(tester);
      await tester.tap(find.byKey(const Key('feed_follow_button')));
      await settle(tester);
      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('Follow is hidden on your own post', (tester) async {
      // The server sends canFollow: false for the viewer's own posts.
      feedOf([_image(1, canFollow: false)]);
      await tester.pumpWidget(subject());
      await settle(tester);
      expect(find.byKey(const Key('feed_follow_button')), findsNothing);
      expect(find.byKey(const Key('feed_like_button')), findsOneWidget);
    });
  });

  group('like', () {
    testWidgets('is optimistic, then adopts the server count', (tester) async {
      feedOf([_image(1, likeCount: 4)]);
      final put = Completer<PostLikeState>();
      when(() => api.setLiked(1, liked: true)).thenAnswer((_) => put.future);
      when(() => api.setLiked(1, liked: false)).thenAnswer(
        (_) async => const PostLikeState(liked: false, likeCount: 8),
      );
      await tester.pumpWidget(subject());
      await settle(tester);

      await tester.tap(find.byKey(const Key('feed_like_button')));
      await tester.pump();
      expect(
        _likeCount(tester),
        '5',
        reason: 'shown before the server answers',
      );
      expect(find.byKey(const Key('feed_like_on')), findsOneWidget);

      put.complete(const PostLikeState(liked: true, likeCount: 9));
      await settle(tester);
      expect(_likeCount(tester), '9', reason: 'reconciled to the server');

      await tester.tap(find.byKey(const Key('feed_like_button')));
      await settle(tester);
      expect(_likeCount(tester), '8');
      expect(find.byKey(const Key('feed_like_off')), findsOneWidget);
    });

    testWidgets('a quick like + unlike ends unliked without double counting', (
      tester,
    ) async {
      feedOf([_image(1)]);
      final put = Completer<PostLikeState>();
      when(() => api.setLiked(1, liked: true)).thenAnswer((_) => put.future);
      when(() => api.setLiked(1, liked: false)).thenAnswer(
        (_) async => const PostLikeState(liked: false, likeCount: 0),
      );
      await tester.pumpWidget(subject());
      await settle(tester);

      await tester.tap(find.byKey(const Key('feed_like_button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('feed_like_button')));
      await tester.pump();
      expect(_likeCount(tester), '0');

      put.complete(const PostLikeState(liked: true, likeCount: 1));
      await settle(tester);
      expect(_likeCount(tester), '0');
      expect(find.byKey(const Key('feed_like_off')), findsOneWidget);
      verify(() => api.setLiked(1, liked: true)).called(1);
      verify(() => api.setLiked(1, liked: false)).called(1);
    });

    testWidgets('a failed like is rolled back', (tester) async {
      feedOf([_image(1, likeCount: 2)]);
      when(() => api.setLiked(1, liked: true)).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      await tester.pumpWidget(subject());
      await settle(tester);
      await tester.tap(find.byKey(const Key('feed_like_button')));
      await settle(tester);
      expect(_likeCount(tester), '2');
      expect(find.byKey(const Key('feed_like_off')), findsOneWidget);
    });
  });

  group('comments', () {
    testWidgets('load, add and delete update the count', (tester) async {
      feedOf([_image(1, commentCount: 1)]);
      when(() => api.comments(1)).thenAnswer(
        (_) async =>
            CommentPage(comments: [_comment(5, 'first!')], commentCount: 1),
      );
      when(() => api.addComment(1, 'nice shot')).thenAnswer(
        (_) async => CommentAdded(
          comment: _comment(6, 'nice shot', canDelete: true),
          commentCount: 2,
        ),
      );
      when(() => api.deleteComment(1, 6)).thenAnswer((_) async => 1);

      await tester.pumpWidget(subject());
      await settle(tester);
      await tester.tap(find.byKey(const Key('feed_comment_button')));
      await settle(tester);

      expect(find.byKey(const Key('feed_comments_sheet')), findsOneWidget);
      expect(find.text('first!'), findsOneWidget);
      expect(find.text('Commenter 5'), findsOneWidget);
      // Only your own comment (or your own post's) offers delete.
      expect(find.byKey(const Key('feed_comment_delete_5')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('feed_comment_input')),
        'nice shot',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('feed_comment_send')));
      await settle(tester);
      expect(find.text('nice shot'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('feed_comments_sheet_count')))
            .data,
        '2',
      );

      // Delete asks in-app first.
      await tester.tap(find.byKey(const Key('feed_comment_delete_6')));
      await settle(tester);
      expect(find.text('Delete comment?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('feed_comment_delete_confirm')));
      await settle(tester);
      expect(find.text('nice shot'), findsNothing);
      verify(() => api.deleteComment(1, 6)).called(1);

      await tester.tap(find.byKey(const Key('feed_comments_close')));
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('feed_comment_count'))).data,
        '1',
      );
    });
  });

  group('share', () {
    testWidgets('showing a post never records a share', (tester) async {
      feedOf([_image(1), _image(2)]);
      await tester.pumpWidget(subject());
      await settle(tester);
      verifyNever(() => api.recordShare(any(), method: any(named: 'method')));
    });

    testWidgets('without a share sheet the link is copied and counted', (
      tester,
    ) async {
      feedOf([_image(1, shareCount: 2)]);
      when(() => api.recordShare(1, method: 'copy')).thenAnswer((_) async => 3);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.pumpWidget(subject());
      await settle(tester);

      await tester.tap(find.byKey(const Key('feed_share_button')));
      await settle(tester);
      expect(copied, 'https://lovcamx.online/feed?post=1');
      expect(find.text('Link copied'), findsOneWidget);
      verify(() => api.recordShare(1, method: 'copy')).called(1);
      expect(
        tester.widget<Text>(find.byKey(const Key('feed_share_count'))).data,
        '3',
      );
    });

    testWidgets('a completed share sheet is counted; a cancelled one is not', (
      tester,
    ) async {
      feedOf([_image(1)]);
      when(() => api.recordShare(1, method: 'native'))
          .thenAnswer((_) async => 1);
      await tester.pumpWidget(subject());
      await settle(tester);

      shareOutcome = NativeShareOutcome.cancelled;
      await tester.tap(find.byKey(const Key('feed_share_button')));
      await settle(tester);
      verifyNever(() => api.recordShare(any(), method: any(named: 'method')));

      shareOutcome = NativeShareOutcome.shared;
      await tester.tap(find.byKey(const Key('feed_share_button')));
      await settle(tester);
      expect(nativeShares, 2);
      verify(() => api.recordShare(1, method: 'native')).called(1);
    });

    testWidgets('a shared link opens on that post', (tester) async {
      feedOf([_image(2), _image(1)]);
      when(() => api.post(9)).thenAnswer((_) async => _image(9));
      await tester.pumpWidget(subject(initialPostId: 9));
      await settle(tester);
      expect(find.text('Author 9'), findsOneWidget);
      expect(find.text('Author 2'), findsNothing);
    });

    testWidgets('a link to a missing post says so', (tester) async {
      feedOf([_image(2)]);
      when(() => api.post(9)).thenThrow(
        const ApiException(kind: ApiErrorKind.notFound, message: 'Not found'),
      );
      await tester.pumpWidget(subject(initialPostId: 9));
      await settle(tester);
      expect(find.byKey(const Key('feed_link_missing')), findsOneWidget);
      expect(find.text('Author 2'), findsOneWidget);
    });
  });

  testWidgets('sound is one setting across posts', (tester) async {
    feedOf([_video(3), _video(2)]);
    await tester.pumpWidget(subject());
    await settle(tester);
    expect(playback.last.volume, 0, reason: 'muted by default');

    await tester.tap(find.byKey(const Key('feed_video_mute')));
    await settle(tester);
    expect(playback.last.volume, 1);

    await tester.fling(
      find.byKey(const Key('feed_pager')),
      const Offset(0, -600),
      1200,
    );
    await settle(tester);
    expect(playback.last.url, 'https://storage.example/2.mp4');
    expect(playback.last.volume, 1, reason: 'the next video keeps the choice');
  });

  group('auto-scroll', () {
    testWidgets('is off by default: a photo stays put', (tester) async {
      feedOf([_image(1), _image(2)]);
      await tester.pumpWidget(subject());
      await settle(tester);
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(find.text('Author 1'), findsOneWidget);
      expect(find.byKey(const Key('feed_autoscroll_resume')), findsNothing);
    });

    testWidgets('a photo advances after 5 seconds, one post at a time', (
      tester,
    ) async {
      await withPrefs({'moco_feed_auto_scroll': true});
      feedOf([_image(1), _image(2), _image(3)]);
      await tester.pumpWidget(subject());
      await settle(tester);

      await tester.pump(const Duration(milliseconds: 3800));
      expect(find.text('Author 1'), findsOneWidget, reason: 'not before 5 s');

      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.text('Author 2'), findsOneWidget);
      expect(find.text('Author 1'), findsNothing);
      expect(find.text('Author 3'), findsNothing, reason: 'exactly one post');
    });

    testWidgets('a video advances when it ends (and does not loop)', (
      tester,
    ) async {
      await withPrefs({'moco_feed_auto_scroll': true});
      feedOf([_video(3), _video(2)]);
      await tester.pumpWidget(subject());
      await settle(tester);
      final first = playback.last;
      expect(first.looping, isFalse);

      await tester.pump(const Duration(seconds: 8));
      expect(
        playback.count,
        1,
        reason: 'a video waits for its end, not a timer',
      );

      first.finish();
      await settle(tester);
      expect(playback.last.url, 'https://storage.example/2.mp4');
      expect(first.disposeCount, 1);
    });

    testWidgets('at the end of the list it loads more, then advances', (
      tester,
    ) async {
      await withPrefs({'moco_feed_auto_scroll': true});
      feedOf([_image(2)], nextCursor: 2);
      when(() => api.feed(cursor: 2))
          .thenAnswer((_) async => FeedPage(posts: [_image(1)]));
      await tester.pumpWidget(subject());
      await settle(tester);

      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      verify(() => api.feed(cursor: 2)).called(1);
      expect(find.text('Author 1'), findsOneWidget);
    });

    testWidgets(
      'a touch pauses it for this visit without changing the setting',
      (tester) async {
        await withPrefs({'moco_feed_auto_scroll': true});
        feedOf([_image(1), _image(2)]);
        await tester.pumpWidget(subject());
        await settle(tester);

        await tester.pump(const Duration(seconds: 3));
        await tester.tapAt(const Offset(120, 300));
        await tester.pump(const Duration(seconds: 6));
        await settle(tester);

        expect(find.text('Author 1'), findsOneWidget);
        expect(find.byKey(const Key('feed_autoscroll_resume')), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(FeedScreen)),
        );
        expect(container.read(appPreferencesProvider).feedAutoScroll, isTrue);
      },
    );

    testWidgets('no auto-advance while the comments sheet is open', (
      tester,
    ) async {
      await withPrefs({'moco_feed_auto_scroll': true});
      feedOf([_image(1), _image(2)]);
      when(() => api.comments(1)).thenAnswer((_) async => const CommentPage());
      await tester.pumpWidget(subject());
      await settle(tester);

      await tester.tap(find.byKey(const Key('feed_comment_button')));
      await settle(tester);
      // Resume while the sheet is still up: the sheet alone must hold it.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FeedScreen)),
      );
      expect(container.read(appPreferencesProvider).feedAutoScroll, isTrue);
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      expect(find.byKey(const Key('feed_comments_sheet')), findsOneWidget);

      await tester.tap(find.byKey(const Key('feed_comments_close')));
      await settle(tester);
      expect(find.text('Author 1'), findsOneWidget);
    });

    testWidgets('leaving the Feed and coming back resumes it', (tester) async {
      await withPrefs({'moco_feed_auto_scroll': true});
      feedOf([_image(1), _image(2)]);
      await tester.pumpWidget(subject());
      await settle(tester);

      // Tapping the author is a touch (pause) and leaves the Feed.
      await tester.tap(find.byKey(const Key('feed_author_101')));
      await settle(tester);
      expect(find.text('listener 101'), findsOneWidget);

      GoRouter.of(tester.element(find.text('listener 101'))).pop();
      await settle(tester);
      expect(find.text('Author 1'), findsOneWidget);
      expect(find.byKey(const Key('feed_autoscroll_resume')), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.text('Author 2'), findsOneWidget);
    });

    testWidgets('Resume restarts it in the same visit', (tester) async {
      await withPrefs({'moco_feed_auto_scroll': true});
      feedOf([_image(1), _image(2)]);
      await tester.pumpWidget(subject());
      await settle(tester);
      await tester.tapAt(const Offset(120, 300));
      await settle(tester);

      await tester.tap(find.byKey(const Key('feed_autoscroll_resume')));
      await settle(tester);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.text('Author 2'), findsOneWidget);
    });
  });

  group('App settings', () {
    Widget settings() {
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (_, __) => const AppSettingsScreen(),
          ),
        ],
      );
      return ProviderScope(
        overrides: base,
        child: MaterialApp.router(
          theme: MocoTheme.dark(),
          routerConfig: router,
        ),
      );
    }

    testWidgets(
      'Feed auto-scroll is off by default and is saved when turned on',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(430, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(settings());
        await tester.pumpAndSettle();

        final finder = find.byKey(const Key('app_settings_feed_auto_scroll'));
        expect(finder, findsOneWidget);
        expect(tester.widget<SwitchListTile>(finder).value, isFalse);

        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(finder).value, isTrue);
        final container = ProviderScope.containerOf(tester.element(finder));
        expect(container.read(appPreferencesProvider).feedAutoScroll, isTrue);
      },
    );
  });
}
