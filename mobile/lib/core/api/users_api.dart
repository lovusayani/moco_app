import '../../shared/models/user.dart';
import 'api_client.dart';

class UsersApi {
  const UsersApi(this._client);

  final ApiClient _client;

  /// `GET /users/me` — the canonical user shape.
  Future<MocoUser> me() {
    return _client.request(
      () => _client.dio.get<dynamic>('/users/me'),
      (data) => MocoUser.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `PATCH /users/me`, then re-reads `GET /users/me`.
  ///
  /// The PATCH response returns raw snake_case database columns
  /// (`display_name`) while GET returns camelCase (`displayName`) — see the API
  /// gaps table in mobile/README.md. Rather than parse two shapes for one
  /// resource, this re-reads the canonical endpoint. The extra request is
  /// cheap and keeps a backend inconsistency from leaking into the models.
  Future<MocoUser> updateProfile({
    String? displayName,
    String? avatarUrl,
    String? language,
    String? gender,
  }) async {
    final body = <String, dynamic>{
      if (displayName != null) 'displayName': displayName,
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
      if (language != null) 'language': language,
      if (gender != null) 'gender': gender,
    };

    await _client.request(
      () => _client.dio.patch<dynamic>('/users/me', data: body),
      (data) => data,
    );

    return me();
  }

  /// `POST /users/me/become-listener` → `{ role, kycStatus, kycRequired }`
  ///
  /// Opting in only creates an unverified listener profile; it does not make
  /// the user discoverable. KYC approval is a separate, manual step.
  Future<Map<String, dynamic>> becomeListener() {
    return _client.request(
      () => _client.dio.post<dynamic>('/users/me/become-listener'),
      (data) => Map<String, dynamic>.from(data as Map),
    );
  }

  /// `POST /users/me/fcm-token`
  Future<void> registerPushToken(String token) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/users/me/fcm-token',
        data: {'token': token},
      ),
      (_) {},
    );
  }
}
