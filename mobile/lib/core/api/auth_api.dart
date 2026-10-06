import '../../shared/models/app_config.dart';
import '../../shared/models/user.dart';
import 'api_client.dart';

/// What `POST /auth/otp/send` reports back. Never contains the code.
class OtpSent {
  const OtpSent({required this.expiresIn, required this.resendIn});

  /// Seconds the code stays valid.
  final int expiresIn;

  /// Seconds until another code may be requested.
  final int resendIn;
}

/// Sign-in endpoints from docs/API.md: one code flow for every channel.
///
/// Codes are single-use and rate limited (cooldown between sends, a few sends
/// per hour per email/phone, per-IP limits). Nothing here retries a verify
/// automatically — a retry would burn the user's remaining attempts.
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  /// `POST /auth/otp/send` `{ channel, identifier }` → `{ sent, expiresIn, resendIn }`
  ///
  /// [identifier] is an email address for [OtpChannel.email] and an E.164
  /// phone number (+919876543210) for the phone channels.
  Future<OtpSent> sendOtp({
    required OtpChannel channel,
    required String identifier,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/auth/otp/send',
        data: {'channel': channel.name, 'identifier': identifier},
      ),
      (data) {
        final map = data as Map;
        return OtpSent(
          expiresIn: (map['expiresIn'] as num?)?.toInt() ?? 300,
          resendIn: (map['resendIn'] as num?)?.toInt() ?? 30,
        );
      },
    );
  }

  /// `POST /auth/otp/verify` `{ channel, identifier, code }` → `{ token, isNew, user }`
  Future<AuthSession> verifyOtp({
    required OtpChannel channel,
    required String identifier,
    required String code,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/auth/otp/verify',
        data: {'channel': channel.name, 'identifier': identifier, 'code': code},
      ),
      (data) => AuthSession.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}
