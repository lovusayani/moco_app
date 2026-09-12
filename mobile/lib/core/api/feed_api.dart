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

  /// `DELETE /feed/:postId` — the caller's own post only. Idempotent.
  Future<void> deletePost(int postId) {
    return _client.request(
      () => _client.dio.delete<dynamic>('/feed/$postId'),
      (_) {},
    );
  }
}
