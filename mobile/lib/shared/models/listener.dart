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

  /// Discovery only ever returns KYC-approved listeners, so anyone the client
  /// can see here has passed verification. There is no per-listener flag.
  bool get isVerified => true;

  @override
  bool operator ==(Object other) =>
      other is ListenerSummary &&
      other.id == id &&
      other.displayName == displayName &&
      other.isOnline == isOnline &&
      other.isBusy == isBusy &&
      other.audioRate == audioRate &&
      other.videoRate == videoRate;

  @override
  int get hashCode =>
      Object.hash(id, displayName, isOnline, isBusy, audioRate, videoRate);
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
    this.isOnline = false,
    this.isBusy = false,
    this.rating = 0,
    this.ratingCount = 0,
    this.totalCalls = 0,
  });

  final int id;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final List<String> languages;
  final String? gender;
  final int audioRate;
  final int videoRate;
  final bool isOnline;
  final bool isBusy;
  final double rating;
  final int ratingCount;
  final int totalCalls;

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
      isOnline: json['isOnline'] as bool? ?? false,
      isBusy: json['isBusy'] as bool? ?? false,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
      totalCalls: (json['totalCalls'] as num?)?.toInt() ?? 0,
    );
  }

  String get name => (displayName?.trim().isNotEmpty ?? false)
      ? displayName!.trim()
      : 'Listener';

  bool get isAvailable => isOnline && !isBusy;
  bool get isVerified => true;

  ListenerDetail copyWith({
    String? displayName,
    String? avatarUrl,
    String? bio,
    List<String>? languages,
    int? audioRate,
    int? videoRate,
    bool? isOnline,
    bool? isBusy,
    double? rating,
    int? ratingCount,
    int? totalCalls,
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
      isOnline: isOnline ?? this.isOnline,
      isBusy: isBusy ?? this.isBusy,
      rating: rating ?? this.rating,
      ratingCount: ratingCount ?? this.ratingCount,
      totalCalls: totalCalls ?? this.totalCalls,
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
