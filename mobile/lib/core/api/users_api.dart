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

  /// `PATCH /users/me`
  ///
  /// Returns the same canonical shape as GET, so the response is used directly.
  /// This previously had to re-read GET because PATCH returned raw snake_case
  /// columns; the backend now serialises both through one projection, which
  /// removes a whole round trip from profile setup.
  Future<MocoUser> updateProfile({
    String? displayName,
    String? avatarUrl,
    String? language,
    String? gender,
  }) {
    final body = <String, dynamic>{
      if (displayName != null) 'displayName': displayName,
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
      if (language != null) 'language': language,
      if (gender != null) 'gender': gender,
    };

    return _client.request(
      () => _client.dio.patch<dynamic>('/users/me', data: body),
      (data) => MocoUser.fromJson(Map<String, dynamic>.from(data as Map)),
    );
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
