import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/feed/feed_controller.dart';
import 'package:moco/shared/models/feed.dart';

class _MockFeedApi extends Mock implements FeedApi {}

Post _post(int id) => Post(
  id: id,
  mediaType: PostMediaType.image,
  mediaUrl: 'https://storage.example/$id.jpg',
  createdAt: DateTime(2026, 2, 1, 10),
  author: const PostAuthor(id: 7, name: 'Priya'),
);

/// Newest first, as the server orders them.
FeedPage _page(List<int> ids, {int? nextCursor}) =>
    FeedPage(posts: ids.map(_post).toList(), nextCursor: nextCursor);

void main() {
  late _MockFeedApi api;

  setUp(() {
    api = _MockFeedApi();
  });

  Future<FeedController> loaded() async {
    final controller = FeedController(api);
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  test('loads the first page newest-first', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4, 3]));

    final controller = await loaded();

    expect(controller.state.posts.map((p) => p.id), [5, 4, 3]);
    expect(controller.state.isLoading, isFalse);
    expect(controller.state.error, isNull);
    controller.dispose();
  });

  test('an empty first page reports isEmpty rather than an error', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([]));

    final controller = await loaded();

    expect(controller.state.isEmpty, isTrue);
    expect(controller.state.error, isNull);
    controller.dispose();
  });

  test('a failed first load is a fatal error the screen can retry', () async {
    when(() => api.feed()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );

    final controller = await loaded();

    expect(controller.state.isFatalError, isTrue);
    expect(controller.state.isLoading, isFalse);
    controller.dispose();
  });

  test('retrying after a failure replaces the error with posts', () async {
    when(() => api.feed()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );
    final controller = await loaded();
    expect(controller.state.isFatalError, isTrue);

    when(() => api.feed()).thenAnswer((_) async => _page([2, 1]));
    await controller.load();

    expect(controller.state.error, isNull);
    expect(controller.state.posts.map((p) => p.id), [2, 1]);
    controller.dispose();
  });

  test('loadMore appends the next page using the cursor', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4], nextCursor: 4));
    final controller = await loaded();

    when(() => api.feed(cursor: 4)).thenAnswer((_) async => _page([3, 2]));
    await controller.loadMore();

    expect(controller.state.posts.map((p) => p.id), [5, 4, 3, 2]);
    verify(() => api.feed(cursor: 4)).called(1);
    controller.dispose();
  });

  test('loadMore does nothing once the feed has ended', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4]));
    final controller = await loaded();

    await controller.loadMore();

    // Only the initial load; no cursor request was ever made.
    verify(() => api.feed()).called(1);
    verifyNever(() => api.feed(cursor: any(named: 'cursor')));
    controller.dispose();
  });

  test('a post returned twice across pages appears once', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4], nextCursor: 4));
    final controller = await loaded();

    // An overlapping page — what a refresh racing a page load can produce.
    when(() => api.feed(cursor: 4)).thenAnswer((_) async => _page([4, 3]));
    await controller.loadMore();

    expect(controller.state.posts.map((p) => p.id), [5, 4, 3]);
    controller.dispose();
  });

  test('a failed loadMore keeps the posts already on screen', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4], nextCursor: 4));
    final controller = await loaded();

    when(() => api.feed(cursor: 4)).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );
    await controller.loadMore();

    expect(controller.state.posts.map((p) => p.id), [5, 4]);
    expect(controller.state.error, isNotNull);
    // Not fatal — the feed is still usable, only the next page failed.
    expect(controller.state.isFatalError, isFalse);
    controller.dispose();
  });

  test('a second loadMore while one is in flight does not double-fetch', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4], nextCursor: 4));
    final controller = await loaded();

    when(() => api.feed(cursor: 4)).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return _page([3, 2]);
    });

    // A snap feed fires the near-the-end check on every settle, so this is a
    // routine path, not an edge case.
    final first = controller.loadMore();
    final second = controller.loadMore();
    await Future.wait([first, second]);

    verify(() => api.feed(cursor: 4)).called(1);
    expect(controller.state.posts.map((p) => p.id), [5, 4, 3, 2]);
    controller.dispose();
  });

  test('refreshing replaces the list rather than merging stale posts', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4], nextCursor: 4));
    final controller = await loaded();

    // Post 4 was deleted server-side between loads.
    when(() => api.feed()).thenAnswer((_) async => _page([6, 5]));
    await controller.load();

    expect(controller.state.posts.map((p) => p.id), [6, 5]);
    controller.dispose();
  });

  test('prepend puts a new post on top without duplicating it', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4]));
    final controller = await loaded();

    controller.prepend(_post(9));
    expect(controller.state.posts.map((p) => p.id), [9, 5, 4]);

    // Publishing, then a refresh that also returns it, must not double it up.
    controller.prepend(_post(9));
    expect(controller.state.posts.map((p) => p.id), [9, 5, 4]);
    controller.dispose();
  });

  test('removeLocally drops a deleted or blocked post immediately', () async {
    when(() => api.feed()).thenAnswer((_) async => _page([5, 4, 3]));
    final controller = await loaded();

    controller.removeLocally(4);

    expect(controller.state.posts.map((p) => p.id), [5, 3]);
    controller.dispose();
  });
}
