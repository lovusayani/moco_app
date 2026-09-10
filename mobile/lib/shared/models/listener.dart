/// A listener as shown on a discovery card (`GET /api/listeners`).
///
/// Rates come from the backend per listener and are never recomputed here —
/// `listener_profiles` allows a per-listener rate, so a hardcoded 6/12 in the
/// client would silently misprice anyone on a custom rate.
class ListenerSummary {
  const ListenerSummary({
    required this.id,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.languages = const [],
    this.gender,
    required this.audioRate,
    required this.videoRate,
    this.acceptsAudio = true,
    this.acceptsVideo = true,
    this.verified = false,
    this.isOnline = false,
    this.isBusy = false,
    this.rating = 0,
    this.totalCalls = 0,
  });

  final int id;

  /// The API returns this as `name`.
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final List<String> languages;
  final String? gender;
  final int audioRate;
  final int videoRate;

  /// Which call types this listener actually takes.
  final bool acceptsAudio;
  final bool acceptsVideo;

  /// Published by the server as a plain boolean; KYC internals are not exposed.
  final bool verified;

  final bool isOnline;
  final bool isBusy;
  final double rating;
  final int totalCalls;

  factory ListenerSummary.fromJson(Map<String, dynamic> json) {
    return ListenerSummary(
      id: (json['id'] as num).toInt(),
      displayName: json['name'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      bio: json['bio'] as String?,
      languages: _stringList(json['languages']),
      gender: json['gender'] as String?,
      audioRate: (json['audioRate'] as num?)?.toInt() ?? 0,
      videoRate: (json['videoRate'] as num?)?.toInt() ?? 0,
      acceptsAudio: json['acceptsAudio'] as bool? ?? true,
      acceptsVideo: json['acceptsVideo'] as bool? ?? true,
      verified: json['verified'] as bool? ?? false,
      isOnline: json['isOnline'] as bool? ?? false,
      isBusy: json['isBusy'] as bool? ?? false,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      totalCalls: (json['totalCalls'] as num?)?.toInt() ?? 0,
    );
  }

  String get name => (displayName?.trim().isNotEmpty ?? false)
      ? displayName!.trim()
      : 'Listener';

  /// Available to take a call right now.
  bool get isAvailable => isOnline && !isBusy;

  /// Applies a live presence update from the socket without refetching.
  ListenerSummary withPresence({required bool isOnline, required bool isBusy}) {
    return ListenerSummary(
      id: id,
      displayName: displayName,
      avatarUrl: avatarUrl,
      bio: bio,
      languages: languages,
      gender: gender,
      audioRate: audioRate,
      videoRate: videoRate,
      acceptsAudio: acceptsAudio,
      acceptsVideo: acceptsVideo,
      verified: verified,
      isOnline: isOnline,
      isBusy: isBusy,
      rating: rating,
      totalCalls: totalCalls,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ListenerSummary &&
      other.id == id &&
      other.displayName == displayName &&
      other.isOnline == isOnline &&
      other.isBusy == isBusy &&
      other.audioRate == audioRate &&
      other.videoRate == videoRate &&
      other.acceptsAudio == acceptsAudio &&
      other.acceptsVideo == acceptsVideo &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    isOnline,
    isBusy,
    audioRate,
    videoRate,
    acceptsAudio,
    acceptsVideo,
    verified,
  );
}

/// A listener profile (`GET /api/listeners/:id`) — the summary plus rating count.
class ListenerDetail {
  const ListenerDetail({
    required this.id,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.languages = const [],
    this.gender,
    required this.audioRate,
    required this.videoRate,
    this.acceptsAudio = true,
    this.acceptsVideo = true,
    this.verified = false,
    this.isOnline = false,
    this.isBusy = false,
    this.rating = 0,
    this.ratingCount = 0,
    this.totalCalls = 0,
    this.isFavorited = false,
    this.isFollowing = false,
    this.followerCount = 0,
  });

  final int id;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final List<String> languages;
  final String? gender;
  final int audioRate;
  final int videoRate;
  final bool acceptsAudio;
  final bool acceptsVideo;
  final bool verified;
  final bool isOnline;
  final bool isBusy;
  final double rating;
  final int ratingCount;
  final int totalCalls;

  /// The VIEWER's relation to this listener, as reported by the server.
  final bool isFavorited;
  final bool isFollowing;
  final int followerCount;

  factory ListenerDetail.fromJson(Map<String, dynamic> json) {
    return ListenerDetail(
      id: (json['id'] as num).toInt(),
      displayName: json['name'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      bio: json['bio'] as String?,
      languages: _stringList(json['languages']),
      gender: json['gender'] as String?,
      audioRate: (json['audioRate'] as num?)?.toInt() ?? 0,
      videoRate: (json['videoRate'] as num?)?.toInt() ?? 0,
      acceptsAudio: json['acceptsAudio'] as bool? ?? true,
      acceptsVideo: json['acceptsVideo'] as bool? ?? true,
      verified: json['verified'] as bool? ?? false,
      isOnline: json['isOnline'] as bool? ?? false,
      isBusy: json['isBusy'] as bool? ?? false,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
      totalCalls: (json['totalCalls'] as num?)?.toInt() ?? 0,
      isFavorited: json['isFavorited'] as bool? ?? false,
      isFollowing: json['isFollowing'] as bool? ?? false,
      followerCount: (json['followerCount'] as num?)?.toInt() ?? 0,
    );
  }

  String get name => (displayName?.trim().isNotEmpty ?? false)
      ? displayName!.trim()
      : 'Listener';

  bool get isAvailable => isOnline && !isBusy;

  ListenerDetail copyWith({
    String? displayName,
    String? avatarUrl,
    String? bio,
    List<String>? languages,
    int? audioRate,
    int? videoRate,
    bool? acceptsAudio,
    bool? acceptsVideo,
    bool? verified,
    bool? isOnline,
    bool? isBusy,
    double? rating,
    int? ratingCount,
    int? totalCalls,
    bool? isFavorited,
    bool? isFollowing,
    int? followerCount,
  }) {
    return ListenerDetail(
      id: id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      languages: languages ?? this.languages,
      gender: gender,
      audioRate: audioRate ?? this.audioRate,
      videoRate: videoRate ?? this.videoRate,
      acceptsAudio: acceptsAudio ?? this.acceptsAudio,
      acceptsVideo: acceptsVideo ?? this.acceptsVideo,
      verified: verified ?? this.verified,
      isOnline: isOnline ?? this.isOnline,
      isBusy: isBusy ?? this.isBusy,
      rating: rating ?? this.rating,
      ratingCount: ratingCount ?? this.ratingCount,
      totalCalls: totalCalls ?? this.totalCalls,
      isFavorited: isFavorited ?? this.isFavorited,
      isFollowing: isFollowing ?? this.isFollowing,
      followerCount: followerCount ?? this.followerCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ListenerDetail &&
      other.id == id &&
      other.displayName == displayName &&
      other.isOnline == isOnline &&
      other.isBusy == isBusy &&
      other.audioRate == audioRate &&
      other.videoRate == videoRate &&
      other.rating == rating;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    isOnline,
    isBusy,
    audioRate,
    videoRate,
    rating,
  );
}

/// One page of discovery results.
///
/// `nextOffset` is null when the backend returned a short page, which is the
/// only end-of-list signal the API gives.
class DiscoveryPage {
  const DiscoveryPage({this.listeners = const [], this.nextOffset});

  final List<ListenerSummary> listeners;
  final int? nextOffset;

  factory DiscoveryPage.fromJson(Map<String, dynamic> json) {
    final raw = json['listeners'];
    return DiscoveryPage(
      listeners: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (e) => ListenerSummary.fromJson(Map<String, dynamic>.from(e)),
                )
                .toList()
          : const [],
      nextOffset: (json['nextOffset'] as num?)?.toInt(),
    );
  }

  bool get hasMore => nextOffset != null;
}

/// Tolerates a null or malformed `languages` value rather than throwing — the
/// column is a Postgres array and an empty one arrives in several shapes.
List<String> _stringList(dynamic value) {
  if (value is List) return value.map((e) => e.toString()).toList();
  return const [];
}
