/// Feed domain models, mirroring docs/API.md's Feed section exactly.
///
/// Nothing here is computed client-side: the media URL is a short-lived signed
/// URL the server minted for this read, and whether an author is linkable is
/// the server's `isListener` flag rather than a guess from any other field.
library;

enum PostMediaType {
  image,
  video;

  static PostMediaType fromJson(String? value) =>
      value == 'video' ? PostMediaType.video : PostMediaType.image;
}

/// A post's author, as the feed publishes them.
class PostAuthor {
  const PostAuthor({
    required this.id,
    this.name,
    this.avatarUrl,
    this.isListener = false,
    this.verified = false,
  });

  final int id;
  final String? name;
  final String? avatarUrl;

  /// Whether tapping this author has somewhere to go. The only profile screen
  /// that exists is the listener profile, so a non-listener author is rendered
  /// without a link rather than pushed to a route that cannot load.
  final bool isListener;

  /// The server's derived KYC boolean. Raw KYC status never reaches a client.
  final bool verified;

  String get displayName =>
      (name?.trim().isNotEmpty ?? false) ? name!.trim() : 'Moco user';

  factory PostAuthor.fromJson(Map<String, dynamic> json) {
    return PostAuthor(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      isListener: json['isListener'] as bool? ?? false,
      verified: json['verified'] as bool? ?? false,
    );
  }
}

/// One feed post.
class Post {
  const Post({
    required this.id,
    required this.mediaType,
    this.mediaUrl,
    this.caption,
    required this.createdAt,
    required this.author,
  });

  final int id;
  final PostMediaType mediaType;

  /// Short-lived signed URL, or null when the backend could not mint one
  /// (storage unconfigured, or the object is gone). The item then shows a
  /// media error state — the rest of the feed still works.
  final String? mediaUrl;
  final String? caption;
  final DateTime createdAt;
  final PostAuthor author;

  bool get isVideo => mediaType == PostMediaType.video;

  /// True only when there is something playable/displayable to show.
  bool get hasMedia => mediaUrl != null && mediaUrl!.isNotEmpty;

  bool get hasCaption => caption?.trim().isNotEmpty ?? false;

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: (json['id'] as num).toInt(),
      mediaType: PostMediaType.fromJson(json['mediaType'] as String?),
      mediaUrl: json['mediaUrl'] as String?,
      caption: json['caption'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      author: PostAuthor.fromJson(
        Map<String, dynamic>.from(json['author'] as Map? ?? const {}),
      ),
    );
  }
}

/// One page of the feed (`GET /feed`), newest first.
class FeedPage {
  const FeedPage({this.posts = const [], this.nextCursor});

  final List<Post> posts;

  /// The id to pass as `cursor` for the next page. Null means end of feed —
  /// the server only omits it when a page came back short, which is the one
  /// reliable signal there is nothing older.
  final int? nextCursor;

  bool get hasMore => nextCursor != null;

  factory FeedPage.fromJson(Map<String, dynamic> json) {
    final raw = json['posts'];
    return FeedPage(
      posts: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => Post.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      nextCursor: (json['nextCursor'] as num?)?.toInt(),
    );
  }
}

/// Response of `POST /feed/media/upload-url`.
///
/// The client PUTs the media bytes straight to [uploadUrl] — it never travels
/// through the Moco API. [token] belongs to Supabase Storage's signed-upload
/// protocol and is not a credential for this backend.
class PostUploadAuthorization {
  const PostUploadAuthorization({
    required this.path,
    required this.uploadUrl,
    required this.token,
    required this.mediaType,
    required this.maxBytes,
    required this.maxVideoSeconds,
  });

  final String path;
  final String uploadUrl;
  final String token;

  /// Decided by the server from the MIME type, not by the client.
  final PostMediaType mediaType;
  final int maxBytes;
  final int maxVideoSeconds;

  factory PostUploadAuthorization.fromJson(Map<String, dynamic> json) {
    return PostUploadAuthorization(
      path: json['path'] as String? ?? '',
      uploadUrl: json['uploadUrl'] as String? ?? '',
      token: json['token'] as String? ?? '',
      mediaType: PostMediaType.fromJson(json['mediaType'] as String?),
      maxBytes: (json['maxBytes'] as num?)?.toInt() ?? 8 * 1024 * 1024,
      maxVideoSeconds: (json['maxVideoSeconds'] as num?)?.toInt() ?? 60,
    );
  }
}

/// The MIME types the backend accepts, kept in one place so the picker and the
/// upload request cannot disagree. Mirrors `FEED_MEDIA` in the backend's
/// constants.js — the server validates these again regardless.
class PostMediaMimeTypes {
  const PostMediaMimeTypes._();

  static const image = <String>['image/jpeg', 'image/png', 'image/webp'];
  static const video = <String>['video/mp4', 'video/quicktime'];

  /// Best-effort MIME type for a picked file, from its extension. The server
  /// re-derives the media type from the path it minted, so a wrong guess here
  /// is refused rather than mis-stored.
  static String? forFileName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    switch (name.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      default:
        return null;
    }
  }
}
