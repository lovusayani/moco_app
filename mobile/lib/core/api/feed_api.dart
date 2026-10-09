import '../../shared/models/feed.dart';
import 'api_client.dart';

class FeedApi {
  const FeedApi(this._client);

  final ApiClient _client;

  /// `GET /feed` — one newest-first page. [cursor] is the id of the last post
  /// already held; the server returns strictly older ones (keyset pagination,
  /// so publishing mid-scroll cannot skip or repeat a post).
  Future<FeedPage> feed({int limit = 10, int? cursor}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/feed',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor},
      ),
      (data) => FeedPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /feed/media/upload-url` — authorizes an upload. The caller PUTs the
  /// media bytes straight to [PostUploadAuthorization.uploadUrl]; this API is
  /// never handed the media itself.
  Future<PostUploadAuthorization> requestUploadUrl(String mimeType) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/feed/media/upload-url',
        data: {'mimeType': mimeType},
      ),
      (data) => PostUploadAuthorization.fromJson(
        Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  /// `POST /feed` — publishes a post for media already uploaded to [mediaPath].
  ///
  /// The media type is NOT sent: the server derives it from the path it
  /// minted, so there is nothing here for a client to get wrong or spoof.
  Future<Post> createPost({required String mediaPath, String? caption}) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/feed',
        data: {
          'mediaPath': mediaPath,
          if (caption != null && caption.trim().isNotEmpty)
            'caption': caption.trim(),
        },
      ),
      (data) =>
          Post.fromJson(Map<String, dynamic>.from((data as Map)['post'] as Map)),
    );
  }

  /// `GET /feed/:postId` — one post, for a shared link.
  Future<Post> post(int postId) {
    return _client.request(
      () => _client.dio.get<dynamic>('/feed/$postId'),
      (data) =>
          Post.fromJson(Map<String, dynamic>.from((data as Map)['post'] as Map)),
    );
  }

  /// `PUT` / `DELETE /feed/:postId/like`. Idempotent server-side; the answer
  /// is the resulting state, which an optimistic client reconciles to.
  Future<PostLikeState> setLiked(int postId, {required bool liked}) {
    return _client.request(
      () => liked
          ? _client.dio.put<dynamic>('/feed/$postId/like')
          : _client.dio.delete<dynamic>('/feed/$postId/like'),
      (data) => PostLikeState.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `GET /feed/:postId/comments` — newest first.
  Future<CommentPage> comments(int postId, {int? cursor}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/feed/$postId/comments',
        queryParameters: {if (cursor != null) 'cursor': cursor},
      ),
      (data) => CommentPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /feed/:postId/comments`.
  Future<CommentAdded> addComment(int postId, String body) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/feed/$postId/comments',
        data: {'body': body},
      ),
      (data) {
        final json = Map<String, dynamic>.from(data as Map);
        return CommentAdded(
          comment: PostComment.fromJson(
            Map<String, dynamic>.from(json['comment'] as Map),
          ),
          commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
        );
      },
    );
  }

  /// `DELETE /feed/:postId/comments/:commentId` — returns the new total.
  Future<int> deleteComment(int postId, int commentId) {
    return _client.request(
      () => _client.dio.delete<dynamic>('/feed/$postId/comments/$commentId'),
      (data) => ((data as Map)['commentCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// `POST /feed/:postId/share` — called only after a share sheet completed
  /// or a link was copied, never on render. Returns the post's share count.
  Future<int> recordShare(int postId, {required String method}) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/feed/$postId/share',
        data: {'method': method},
      ),
      (data) => ((data as Map)['shareCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// `DELETE /feed/:postId` — the caller's own post only. Idempotent.
  Future<void> deletePost(int postId) {
    return _client.request(
      () => _client.dio.delete<dynamic>('/feed/$postId'),
      (_) {},
    );
  }
}
