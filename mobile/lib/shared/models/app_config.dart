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
class AppConfig {
  const AppConfig({
    required this.rates,
    this.packs = const [],
    this.freeTrialSeconds = 60,
    this.languages = const ['en', 'hi', 'te'],
    this.minAppVersion = '1.0.0',
  });

  final CallRates rates;
  final List<CoinPack> packs;
  final int freeTrialSeconds;
  final List<String> languages;
  final String minAppVersion;

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
    );
  }
}
