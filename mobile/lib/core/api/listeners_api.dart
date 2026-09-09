import '../../shared/models/listener.dart';
import 'api_client.dart';

/// Filters the discovery endpoint actually supports.
///
/// Deliberately narrow: `GET /api/listeners` accepts only language, gender,
/// online, limit and offset. Anything the design asks for beyond this (free-text
/// search, audio/video capability) has no backend support and is documented as
/// a gap rather than faked client-side.
class DiscoveryFilters {
  const DiscoveryFilters({this.language, this.gender, this.onlineOnly = false});

  final String? language;
  final String? gender;
  final bool onlineOnly;

  bool get isActive => language != null || gender != null || onlineOnly;

  DiscoveryFilters copyWith({
    String? language,
    String? gender,
    bool? onlineOnly,
    bool clearLanguage = false,
    bool clearGender = false,
  }) {
    return DiscoveryFilters(
      language: clearLanguage ? null : (language ?? this.language),
      gender: clearGender ? null : (gender ?? this.gender),
      onlineOnly: onlineOnly ?? this.onlineOnly,
    );
  }

  Map<String, dynamic> toQuery({required int limit, required int offset}) {
    return <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (language != null) 'language': language,
      if (gender != null) 'gender': gender,
      if (onlineOnly) 'online': true,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryFilters &&
      other.language == language &&
      other.gender == gender &&
      other.onlineOnly == onlineOnly;

  @override
  int get hashCode => Object.hash(language, gender, onlineOnly);
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
      () => _client.dio.get<dynamic>('/listeners/$id'),
      (data) => ListenerDetail.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}
