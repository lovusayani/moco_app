import 'package:flutter_test/flutter_test.dart';
import 'package:moco/shared/models/feed.dart';

void main() {
  group('Post.fromJson', () {
    test('parses an image post with an author', () {
      final post = Post.fromJson({
        'id': 12,
        'mediaType': 'image',
        'mediaUrl': 'https://storage.example/signed/a.jpg',
        'caption': 'hello',
        'createdAt': '2026-02-01T10:00:00.000Z',
        'author': {
          'id': 7,
          'name': 'Priya',
          'avatarUrl': 'https://cdn.example/p.jpg',
          'isListener': true,
          'verified': true,
        },
      });

      expect(post.id, 12);
      expect(post.isVideo, isFalse);
      expect(post.hasMedia, isTrue);
      expect(post.hasCaption, isTrue);
      expect(post.author.displayName, 'Priya');
      expect(post.author.isListener, isTrue);
      expect(post.author.verified, isTrue);
    });

    test('parses a video post', () {
      final post = Post.fromJson({
        'id': 3,
        'mediaType': 'video',
        'mediaUrl': 'https://storage.example/signed/a.mp4',
        'createdAt': '2026-02-01T10:00:00.000Z',
        'author': {'id': 1},
      });

      expect(post.isVideo, isTrue);
      expect(post.hasCaption, isFalse);
    });

    test('an unknown media type falls back to image rather than throwing', () {
      // A server that grows a new media type must not crash an older client.
      final post = Post.fromJson({
        'id': 3,
        'mediaType': 'hologram',
        'createdAt': '2026-02-01T10:00:00.000Z',
        'author': {'id': 1},
      });

      expect(post.mediaType, PostMediaType.image);
    });

    test('a null media URL is not treated as media', () {
      // What the server returns when storage is unconfigured, or the object
      // is gone. The item renders a media error rather than a broken surface.
      final post = Post.fromJson({
        'id': 3,
        'mediaType': 'image',
        'mediaUrl': null,
        'createdAt': '2026-02-01T10:00:00.000Z',
        'author': {'id': 1},
      });

      expect(post.hasMedia, isFalse);
    });

    test('a whitespace-only caption does not count as a caption', () {
      final post = Post.fromJson({
        'id': 3,
        'mediaType': 'image',
        'caption': '   ',
        'createdAt': '2026-02-01T10:00:00.000Z',
        'author': {'id': 1},
      });

      expect(post.hasCaption, isFalse);
    });

    test('an author with no name still has a display name', () {
      final post = Post.fromJson({
        'id': 3,
        'mediaType': 'image',
        'createdAt': '2026-02-01T10:00:00.000Z',
        'author': {'id': 1},
      });

      expect(post.author.displayName, 'Moco user');
      expect(post.author.isListener, isFalse);
    });
  });

  group('FeedPage.fromJson', () {
    test('reads posts and the cursor', () {
      final page = FeedPage.fromJson({
        'posts': [
          {
            'id': 2,
            'mediaType': 'image',
            'createdAt': '2026-02-01T10:00:00.000Z',
            'author': {'id': 1},
          },
        ],
        'nextCursor': 2,
      });

      expect(page.posts.length, 1);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 2);
    });

    test('a null cursor is the end of the feed', () {
      final page = FeedPage.fromJson({'posts': [], 'nextCursor': null});
      expect(page.hasMore, isFalse);
      expect(page.posts, isEmpty);
    });

    test('a malformed posts field yields an empty page, not a crash', () {
      final page = FeedPage.fromJson({'posts': 'nope'});
      expect(page.posts, isEmpty);
    });
  });

  group('PostUploadAuthorization', () {
    test('carries the server-decided media type and caps', () {
      final auth = PostUploadAuthorization.fromJson({
        'path': '7/abc.mp4',
        'uploadUrl': 'https://storage.example/upload',
        'token': 'tok',
        'mediaType': 'video',
        'maxBytes': 64 * 1024 * 1024,
        'maxVideoSeconds': 60,
      });

      expect(auth.mediaType, PostMediaType.video);
      expect(auth.maxBytes, 64 * 1024 * 1024);
      expect(auth.maxVideoSeconds, 60);
    });
  });

  group('PostMediaMimeTypes.forFileName', () {
    test('maps the extensions the backend mints', () {
      expect(PostMediaMimeTypes.forFileName('a.jpg'), 'image/jpeg');
      expect(PostMediaMimeTypes.forFileName('a.JPEG'), 'image/jpeg');
      expect(PostMediaMimeTypes.forFileName('a.png'), 'image/png');
      expect(PostMediaMimeTypes.forFileName('a.webp'), 'image/webp');
      expect(PostMediaMimeTypes.forFileName('a.mp4'), 'video/mp4');
      expect(PostMediaMimeTypes.forFileName('a.mov'), 'video/quicktime');
    });

    test('refuses anything else rather than guessing', () {
      expect(PostMediaMimeTypes.forFileName('a.exe'), isNull);
      expect(PostMediaMimeTypes.forFileName('noextension'), isNull);
    });
  });
}
