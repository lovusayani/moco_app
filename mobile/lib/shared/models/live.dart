/// Moco Live — external live models (first provider: Stripcash), as served by
/// `GET /api/live/config` and `GET /api/live/models`.
///
/// Everything about how Live looks comes from the admin's saved settings in
/// [LiveConfig]; nothing here is a hard-coded presentation choice. Parsing is
/// tolerant: an unknown or missing value falls back to the backend's own
/// default, so a newer backend never breaks an older client.
library;

enum LiveLayoutPreset { grid, large, compact, mixed }

enum LiveAspect { portrait, square, landscape, wide }

enum LiveDensity { comfortable, cozy, compact }

enum LiveRadius { none, small, medium, large }

enum LiveClickBehavior { internalPlayer, provider }

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}

int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;

class LiveColumns {
  const LiveColumns({this.mobile = 2, this.tablet = 3, this.desktop = 4});

  final int mobile;
  final int tablet;
  final int desktop;

  factory LiveColumns.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return LiveColumns(
      mobile: _int(m['mobile'], 2).clamp(1, 3),
      tablet: _int(m['tablet'], 3).clamp(2, 4),
      desktop: _int(m['desktop'], 4).clamp(2, 6),
    );
  }

  /// Columns for an available width: phone, tablet or desktop class.
  int forWidth(double width) {
    if (width < 600) return mobile;
    if (width < 1024) return tablet;
    return desktop;
  }
}

class LiveLayout {
  const LiveLayout({
    this.preset = LiveLayoutPreset.grid,
    this.columns = const LiveColumns(),
    this.aspect = LiveAspect.portrait,
    this.density = LiveDensity.comfortable,
    this.radius = LiveRadius.medium,
  });

  final LiveLayoutPreset preset;
  final LiveColumns columns;
  final LiveAspect aspect;
  final LiveDensity density;
  final LiveRadius radius;

  factory LiveLayout.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return LiveLayout(
      preset: _enumByName(
        LiveLayoutPreset.values,
        m['preset'],
        LiveLayoutPreset.grid,
      ),
      columns: LiveColumns.fromJson(m['columns']),
      aspect: _enumByName(LiveAspect.values, m['aspect'], LiveAspect.portrait),
      density: _enumByName(
        LiveDensity.values,
        m['density'],
        LiveDensity.comfortable,
      ),
      radius: _enumByName(LiveRadius.values, m['radius'], LiveRadius.medium),
    );
  }

  /// Width / height of a card's image.
  double get aspectRatio => switch (aspect) {
    LiveAspect.portrait => 3 / 4,
    LiveAspect.square => 1,
    LiveAspect.landscape => 4 / 3,
    LiveAspect.wide => 16 / 9,
  };

  double get cornerRadius => switch (radius) {
    LiveRadius.none => 0,
    LiveRadius.small => 8,
    LiveRadius.medium => 16,
    LiveRadius.large => 24,
  };

  /// Gap between cards and padding inside a card's text area.
  double get gap => switch (density) {
    LiveDensity.comfortable => 12,
    LiveDensity.cozy => 8,
    LiveDensity.compact => 5,
  };
}

/// Which card fields the admin turned on.
class LiveCardFields {
  const LiveCardFields({
    this.snapshot = true,
    this.avatar = false,
    this.liveBadge = true,
    this.username = true,
    this.viewers = true,
    this.country = true,
    this.languages = false,
    this.favorites = false,
    this.hdBadge = true,
    this.tags = false,
    this.goal = false,
  });

  final bool snapshot;
  final bool avatar;
  final bool liveBadge;
  final bool username;
  final bool viewers;
  final bool country;
  final bool languages;
  final bool favorites;
  final bool hdBadge;
  final bool tags;
  final bool goal;

  factory LiveCardFields.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    bool b(String k, bool fallback) => m[k] is bool ? m[k] as bool : fallback;
    return LiveCardFields(
      snapshot: b('snapshot', true),
      avatar: b('avatar', false),
      liveBadge: b('liveBadge', true),
      username: b('username', true),
      viewers: b('viewers', true),
      country: b('country', true),
      languages: b('languages', false),
      favorites: b('favorites', false),
      hdBadge: b('hdBadge', true),
      tags: b('tags', false),
      goal: b('goal', false),
    );
  }
}

/// Non-secret settings for the official Stripchat player. The player runs
/// in an isolated page on the API's origin ([framePath], relative to the API
/// base URL); the backend injects the script and the affiliate id there, so
/// the app only says which model to show. [scriptUrl] is null — and the app
/// shows its "player not available" state — until the backend has both.
class LivePlayerConfig {
  const LivePlayerConfig({
    required this.userId,
    this.strict = 1,
    this.autoplay = 'playButton',
    this.scriptUrl,
    this.framePath = '/live/player-frame',
  });

  final String userId;
  final int strict;
  final String autoplay;
  final String? scriptUrl;
  final String framePath;

  /// The player can run: the backend has the official script configured.
  bool get available => scriptUrl != null;

  static LivePlayerConfig? fromJson(Object? json) {
    if (json is! Map || json['userId'] is! String) return null;
    final script = json['scriptUrl'];
    final frame = json['framePath'];
    return LivePlayerConfig(
      userId: json['userId'] as String,
      strict: _int(json['strict'], 1),
      autoplay: json['autoplay'] is String
          ? json['autoplay'] as String
          : 'playButton',
      scriptUrl: script is String && script.startsWith('https://')
          ? script
          : null,
      // Only a path on the API itself; never a full URL from the network.
      framePath: frame is String && RegExp(r'^/[a-z0-9/_-]+$').hasMatch(frame)
          ? frame
          : '/live/player-frame',
    );
  }
}

class LiveConfig {
  const LiveConfig({
    required this.enabled,
    this.requireAgeConfirmation = true,
    this.pageSize = 24,
    this.layout = const LiveLayout(),
    this.card = const LiveCardFields(),
    this.sort = 'default',
    this.clickBehavior = LiveClickBehavior.internalPlayer,
    this.player,
  });

  final bool enabled;
  final bool requireAgeConfirmation;
  final int pageSize;
  final LiveLayout layout;
  final LiveCardFields card;
  final String sort;
  final LiveClickBehavior clickBehavior;
  final LivePlayerConfig? player;

  factory LiveConfig.fromJson(Map<String, dynamic> json) {
    return LiveConfig(
      enabled: json['enabled'] == true,
      // Only an explicit false turns the gate off — same rule as the backend.
      requireAgeConfirmation: json['requireAgeConfirmation'] != false,
      pageSize: _int(json['pageSize'], 24).clamp(6, 60),
      layout: LiveLayout.fromJson(json['layout']),
      card: LiveCardFields.fromJson(json['card']),
      sort: json['sort'] is String ? json['sort'] as String : 'default',
      clickBehavior: json['clickBehavior'] == 'provider'
          ? LiveClickBehavior.provider
          : LiveClickBehavior.internalPlayer,
      player: LivePlayerConfig.fromJson(json['player']),
    );
  }
}

class LiveGoal {
  const LiveGoal({this.message, this.needed = 0, this.earned = 0});

  final String? message;
  final int needed;
  final int earned;

  /// 0..1, or null when there is no target to measure against.
  double? get progress =>
      needed > 0 ? (earned / needed).clamp(0, 1).toDouble() : null;

  static LiveGoal? fromJson(Object? json) {
    if (json is! Map) return null;
    return LiveGoal(
      message: json['message'] is String ? json['message'] as String : null,
      needed: _int(json['needed'], 0),
      earned: _int(json['earned'], 0),
    );
  }
}

/// One provider model. Images are the provider's URLs, shown as-is.
class LiveModel {
  const LiveModel({
    required this.id,
    required this.username,
    this.avatarUrl,
    this.snapshotUrl,
    this.thumbnailUrl,
    this.country,
    this.languages = const [],
    this.tags = const [],
    this.viewers = 0,
    this.favorites = 0,
    this.isHd = false,
    this.status = 'public',
    this.featured = false,
    this.goal,
    this.destinationUrl,
  });

  final int id;
  final String username;
  final String? avatarUrl;
  final String? snapshotUrl;
  final String? thumbnailUrl;
  final String? country;
  final List<String> languages;
  final List<String> tags;
  final int viewers;
  final int favorites;
  final bool isHd;
  final String status;
  final bool featured;
  final LiveGoal? goal;

  /// Present only when the admin chose "open provider destination".
  final String? destinationUrl;

  /// The best image for a card: the live snapshot, then the small thumb.
  String? get imageUrl => snapshotUrl ?? thumbnailUrl ?? avatarUrl;

  static List<String> _strings(Object? v) =>
      v is List ? v.whereType<String>().toList(growable: false) : const [];

  static String? _httpsUrl(Object? v) =>
      v is String && v.startsWith('https://') ? v : null;

  factory LiveModel.fromJson(Map<String, dynamic> json) {
    return LiveModel(
      id: _int(json['id'], 0),
      username: json['username'] as String? ?? '',
      avatarUrl: _httpsUrl(json['avatarUrl']),
      snapshotUrl: _httpsUrl(json['snapshotUrl']),
      thumbnailUrl: _httpsUrl(json['thumbnailUrl']),
      country: json['country'] is String ? json['country'] as String : null,
      languages: _strings(json['languages']),
      tags: _strings(json['tags']),
      viewers: _int(json['viewers'], 0),
      favorites: _int(json['favorites'], 0),
      isHd: json['isHd'] == true,
      status: json['status'] as String? ?? 'public',
      featured: json['featured'] == true,
      goal: LiveGoal.fromJson(json['goal']),
      destinationUrl: _httpsUrl(json['destinationUrl']),
    );
  }
}

class LiveModelsPage {
  const LiveModelsPage({
    required this.available,
    required this.models,
    this.limit = 24,
    this.offset = 0,
    this.freshness = 'fresh',
    this.retryAfterMs,
  });

  /// False when Live is off or the provider is not configured.
  final bool available;
  final List<LiveModel> models;
  final int limit;
  final int offset;

  /// The backend's answer to "how current is this list": `fresh`, `stale`
  /// (the last good list, being refreshed), `warming` (no list yet — ask
  /// again after [retryAfterMs]) or `unavailable` (the provider is down and
  /// there is no recent list).
  final String freshness;
  final int? retryAfterMs;

  bool get isWarming => freshness == 'warming';
  bool get isUnavailable => freshness == 'unavailable';

  factory LiveModelsPage.fromJson(Map<String, dynamic> json) {
    final raw = json['models'];
    final retry = json['retryAfterMs'];
    return LiveModelsPage(
      available: json['available'] == true,
      limit: _int(json['limit'], 24),
      offset: _int(json['offset'], 0),
      freshness: json['freshness'] is String
          ? json['freshness'] as String
          : 'fresh',
      retryAfterMs: retry is num ? retry.toInt() : null,
      models: raw is List
          ? raw
                .whereType<Map>()
                .map((m) => LiveModel.fromJson(Map<String, dynamic>.from(m)))
                .where((m) => m.username.isNotEmpty)
                .toList(growable: false)
          : const [],
    );
  }
}
