/// One of the signed-in listener's own profile photos. [url] is a short-lived
/// signed URL to the private `listener-media` bucket, minted per request by
/// the backend — never a permanent public link.
class ListenerPhoto {
  const ListenerPhoto({required this.id, this.url, this.createdAt});

  final int id;
  final String? url;
  final DateTime? createdAt;

  factory ListenerPhoto.fromJson(Map<String, dynamic> json) => ListenerPhoto(
    id: (json['id'] as num).toInt(),
    url: json['url'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );
}

/// `GET /listeners/me/photos` (and the response of add/remove).
class ListenerPhotos {
  const ListenerPhotos({
    this.photos = const [],
    this.minCount = 3,
    this.maxCount = 6,
  });

  final List<ListenerPhoto> photos;
  final int minCount;
  final int maxCount;

  int get count => photos.length;
  bool get meetsMinimum => count >= minCount;
  bool get atMaximum => count >= maxCount;

  factory ListenerPhotos.fromJson(Map<String, dynamic> json) => ListenerPhotos(
    photos: (json['photos'] as List? ?? const [])
        .map((p) => ListenerPhoto.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList(growable: false),
    minCount: (json['minCount'] as num?)?.toInt() ?? 3,
    maxCount: (json['maxCount'] as num?)?.toInt() ?? 6,
  );
}

/// `POST /listeners/me/photos/upload-url`. The app PUTs bytes straight to
/// [uploadUrl] with [token]; the backend minted [path] and will verify the
/// object exists and fits [maxBytes] before recording it.
class ListenerPhotoUploadAuthorization {
  const ListenerPhotoUploadAuthorization({
    required this.path,
    required this.uploadUrl,
    required this.token,
    required this.maxBytes,
  });

  final String path;
  final String uploadUrl;
  final String token;
  final int maxBytes;

  factory ListenerPhotoUploadAuthorization.fromJson(Map<String, dynamic> json) =>
      ListenerPhotoUploadAuthorization(
        path: json['path'] as String,
        uploadUrl: json['uploadUrl'] as String,
        token: json['token'] as String,
        maxBytes: (json['maxBytes'] as num?)?.toInt() ?? 8 * 1024 * 1024,
      );
}
