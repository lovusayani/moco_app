import '../../shared/models/user.dart';
import 'api_client.dart';

/// Auth endpoints from docs/API.md.
///
/// The backend's OTP codes are single-use and rate limited (5 per phone per
/// hour, 10 per IP per 5 minutes). Nothing here retries a verify automatically —
/// a retry would burn the user's remaining attempts.
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  /// `POST /auth/otp/request` → `{ sent, expiresIn }`
  /// Returns the OTP lifetime in seconds, used to drive the resend timer.
  Future<int> requestOtp(String phone) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/auth/otp/request',
        data: {'phone': phone},
      ),
      (data) => (data as Map)['expiresIn'] as int? ?? 300,
    );
  }

  /// `POST /auth/otp/verify` → `{ token, isNew, user }`
  Future<AuthSession> verifyOtp({required String phone, required String code}) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/auth/otp/verify',
        data: {'phone': phone, 'code': code},
      ),
      (data) => AuthSession.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}
