import '../../shared/models/user.dart';
import 'api_client.dart';

/// How a login code is delivered. SMS is the primary channel; WhatsApp is
/// the fallback when an SMS does not arrive. Either way it is the same Moco
/// login code, checked by the same `/auth/otp/verify`.
enum OtpChannel { sms, whatsapp }

/// The backend's answer to a code request.
class OtpRequestResult {
  const OtpRequestResult({
    required this.channel,
    required this.expiresIn,
    this.resendIn = 30,
    this.whatsappFallback = false,
  });

  factory OtpRequestResult.fromJson(Map<String, dynamic> json) {
    final fallback = (json['fallbackChannels'] as List?) ?? const [];
    return OtpRequestResult(
      channel: json['channel'] == 'whatsapp'
          ? OtpChannel.whatsapp
          : OtpChannel.sms,
      expiresIn: json['expiresIn'] as int? ?? 300,
      resendIn: json['resendIn'] as int? ?? 30,
      whatsappFallback: fallback.contains('whatsapp'),
    );
  }

  final OtpChannel channel;

  /// Code lifetime in seconds.
  final int expiresIn;

  /// Server-side cooldown before another code can be requested.
  final int resendIn;

  /// Whether "Send via WhatsApp" can be offered if this code doesn't arrive.
  final bool whatsappFallback;
}

/// Auth endpoints from docs/API.md.
///
/// The backend's OTP codes are single-use and rate limited (a resend
/// cooldown, 5 per phone per hour across channels, 3 WhatsApp per hour, 10 per
/// IP per 5 minutes). Nothing here retries automatically — a retry would
/// burn the user's remaining attempts.
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  /// `POST /auth/otp/request` → `{ sent, channel, expiresIn, resendIn, fallbackChannels }`
  Future<OtpRequestResult> requestOtp(
    String phone, {
    OtpChannel channel = OtpChannel.sms,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/auth/otp/request',
        data: {'phone': phone, 'channel': channel.name},
      ),
      (data) =>
          OtpRequestResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `GET /auth/otp/channels` → `{ sms, whatsapp }`. Used after an SMS hard
  /// failure, to decide whether WhatsApp can be offered right away.
  Future<bool> whatsappAvailable() {
    return _client.request(
      () => _client.dio.get<dynamic>('/auth/otp/channels'),
      (data) => (data as Map)['whatsapp'] == true,
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
