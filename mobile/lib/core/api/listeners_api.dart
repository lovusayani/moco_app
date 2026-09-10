import '../../shared/models/listener.dart';
import 'api_client.dart';

/// Everything `GET /api/listeners` accepts.
///
/// Every field here maps to a real server-side parameter — nothing is applied
/// client-side and then presented to the user as a filter.
class DiscoveryFilters {
  const DiscoveryFilters({
    this.language,
    this.gender,
    this.onlineOnly = false,
    this.query,
    this.callType,
  });

  final String? language;
  final String? gender;
  final bool onlineOnly;

  /// Free-text search, run by the server across the whole listener table.
  final String? query;

  /// Capability filter: 'audio' or 'video'. Null means either.
  final String? callType;

  /// Whether any *filter* is applied. Search is deliberately excluded — an
  /// empty search result wants different copy from an over-filtered one.
  bool get isActive => language != null || gender != null || onlineOnly;

  bool get hasQuery => (query ?? '').trim().isNotEmpty;

  DiscoveryFilters copyWith({
    String? language,
    String? gender,
    bool? onlineOnly,
    String? query,
    String? callType,
    bool clearLanguage = false,
    bool clearGender = false,
    bool clearQuery = false,
    bool clearCallType = false,
  }) {
    return DiscoveryFilters(
      language: clearLanguage ? null : (language ?? this.language),
      gender: clearGender ? null : (gender ?? this.gender),
      onlineOnly: onlineOnly ?? this.onlineOnly,
      query: clearQuery ? null : (query ?? this.query),
      callType: clearCallType ? null : (callType ?? this.callType),
    );
  }

  Map<String, dynamic> toQuery({required int limit, required int offset}) {
    final trimmed = query?.trim();
    return <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (language != null) 'language': language,
      if (gender != null) 'gender': gender,
      if (onlineOnly) 'online': true,
      if (trimmed != null && trimmed.isNotEmpty) 'q': trimmed,
      if (callType != null) 'callType': callType,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryFilters &&
      other.language == language &&
      other.gender == gender &&
      other.onlineOnly == onlineOnly &&
      other.query == query &&
      other.callType == callType;

  @override
  int get hashCode =>
      Object.hash(language, gender, onlineOnly, query, callType);
}

class ListenersApi {
  const ListenersApi(this._client);

  final ApiClient _client;

  static const pageSize = 20;

  /// `GET /listeners` → `{ listeners, nextOffset }`
  Future<DiscoveryPage> discover({
    DiscoveryFilters filters = const DiscoveryFilters(),
    int offset = 0,
    int limit = pageSize,
  }) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/listeners',
        queryParameters: filters.toQuery(limit: limit, offset: offset),
      ),
      (data) => DiscoveryPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `GET /listeners/:id`
  Future<ListenerDetail> byId(int id) {
    return _client.request(
      () => _client.dio.get<dynamic>('/listeners/\$id'),
      (data) => ListenerDetail.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// Sets or clears a favourite/follow relation.
  ///
  /// Both directions are idempotent server-side, so a retry after a dropped
  /// connection is safe and needs no client-side de-duplication.
  Future<RelationResult> setRelation({
    required int listenerId,
    required String kind,
    required bool active,
  }) {
    return _client.request(
      () => active
          ? _client.dio.put<dynamic>('/listeners/\$listenerId/\$kind')
          : _client.dio.delete<dynamic>('/listeners/\$listenerId/\$kind'),
      (data) => RelationResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}

/// Outcome of a favourite/follow write, including the resulting follower count
/// so the profile can update without refetching.
class RelationResult {
  const RelationResult({
    required this.listenerId,
    required this.kind,
    required this.active,
    required this.followerCount,
  });

  final int listenerId;
  final String kind;
  final bool active;
  final int followerCount;

  factory RelationResult.fromJson(Map<String, dynamic> json) {
    return RelationResult(
      listenerId: (json['listenerId'] as num).toInt(),
      kind: json['kind'] as String,
      active: json['active'] as bool? ?? false,
      followerCount: (json['followerCount'] as num?)?.toInt() ?? 0,
    );
  }
}
