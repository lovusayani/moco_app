/// A purchasable coin pack, exactly as the backend publishes it.
///
/// Prices and bonuses are never hardcoded client-side: `constants.js` is the
/// single source of truth and the client renders whatever it is given.
class CoinPack {
  const CoinPack({
    required this.id,
    required this.priceInr,
    required this.coins,
    this.bonus = 0,
  });

  final String id;
  final int priceInr;
  final int coins;
  final int bonus;

  factory CoinPack.fromJson(Map<String, dynamic> json) {
    return CoinPack(
      id: json['id'] as String,
      priceInr: (json['priceInr'] as num).toInt(),
      coins: (json['coins'] as num).toInt(),
      bonus: (json['bonus'] as num?)?.toInt() ?? 0,
    );
  }

  int get totalCoins => coins + bonus;
}

class CallRates {
  const CallRates({required this.audio, required this.video});

  final int audio;
  final int video;

  factory CallRates.fromJson(Map<String, dynamic> json) {
    return CallRates(
      audio: (json['audio'] as num?)?.toInt() ?? 0,
      video: (json['video'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Client bootstrap from `GET /api/config`.
///
/// Fetched on launch so rates, packs and supported languages always match the
/// server, even if the app binary is older than the current pricing.
/// How a sign-in code can be delivered (`GET /config` → `auth.channels`).
enum OtpChannel {
  email,
  sms,
  whatsapp,
  telegram;

  /// Email proves an email address; the others prove a phone number.
  bool get usesPhone => this != OtpChannel.email;

  String get label => switch (this) {
    OtpChannel.email => 'Email',
    OtpChannel.sms => 'SMS',
    OtpChannel.whatsapp => 'WhatsApp',
    OtpChannel.telegram => 'Telegram',
  };

  static OtpChannel? fromId(Object? id) {
    for (final c in OtpChannel.values) {
      if (c.name == id) return c;
    }
    return null;
  }
}

/// Which sign-in methods this backend offers. A channel whose provider is not
/// configured is listed as unavailable and must not be selectable.
class AuthConfig {
  const AuthConfig({
    this.defaultChannel = OtpChannel.email,
    this.available = const {OtpChannel.email},
  });

  final OtpChannel defaultChannel;
  final Set<OtpChannel> available;

  bool isAvailable(OtpChannel channel) => available.contains(channel);

  factory AuthConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AuthConfig();
    final channels = json['channels'];
    final available = <OtpChannel>{
      if (channels is List)
        for (final c in channels.whereType<Map>())
          if (c['available'] == true && OtpChannel.fromId(c['id']) != null)
            OtpChannel.fromId(c['id'])!,
    };
    return AuthConfig(
      defaultChannel:
          OtpChannel.fromId(json['defaultChannel']) ?? OtpChannel.email,
      available: available,
    );
  }
}

class AppConfig {
  const AppConfig({
    required this.rates,
    this.packs = const [],
    this.freeTrialSeconds = 60,
    this.languages = const ['en', 'hi', 'te'],
    this.minAppVersion = '1.0.0',
    this.auth = const AuthConfig(),
  });

  final CallRates rates;
  final List<CoinPack> packs;
  final int freeTrialSeconds;
  final List<String> languages;
  final String minAppVersion;
  final AuthConfig auth;

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final packs = json['packs'];
    final languages = json['languages'];
    return AppConfig(
      rates: CallRates.fromJson(
        Map<String, dynamic>.from(json['rates'] as Map? ?? const {}),
      ),
      packs: packs is List
          ? packs
                .whereType<Map>()
                .map((e) => CoinPack.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      freeTrialSeconds: (json['freeTrialSeconds'] as num?)?.toInt() ?? 60,
      languages: languages is List
          ? languages.map((e) => e.toString()).toList()
          : const ['en', 'hi', 'te'],
      minAppVersion: json['minAppVersion'] as String? ?? '1.0.0',
      auth: AuthConfig.fromJson(
        json['auth'] is Map
            ? Map<String, dynamic>.from(json['auth'] as Map)
            : null,
      ),
    );
  }
}
