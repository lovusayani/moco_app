import 'package:flutter/foundation.dart';

/// Environment configuration, supplied at build time with `--dart-define`.
///
/// Nothing here is a secret: the API base URL and the Agora app ID are public
/// client identifiers. Real secrets stay server-side — the client never holds
/// an Agora certificate, a payment key, or anything that signs a request.
enum AppFlavor { development, staging, production }

class Env {
  const Env._();

  static const String _flavorName = String.fromEnvironment(
    'FLAVOR',
    defaultValue: 'development',
  );

  static AppFlavor get flavor => switch (_flavorName) {
    'production' => AppFlavor.production,
    'staging' => AppFlavor.staging,
    _ => AppFlavor.development,
  };

  static bool get isProduction => flavor == AppFlavor.production;
  static bool get isDevelopment => flavor == AppFlavor.development;

  /// Base URL of the Node backend, including the `/api` prefix used by every
  /// route in docs/API.md.
  ///
  /// Native default: the Android emulator, where 10.0.2.2 is the host
  /// machine's loopback — a plain localhost would resolve to the emulator.
  ///
  /// Web default: the page's own origin (local `tool/serve_web.mjs` proxies
  /// `/api` and `/socket.io` to a local backend). The production web build
  /// passes `API_BASE_URL=https://api.lovcamx.online/api` (see
  /// `tool/vercel/build_web.mjs`), and the API allows that origin via CORS.
  /// A `--dart-define` wins on either platform.
  static String get apiBaseUrl => _apiBaseUrlDefine.isNotEmpty
      ? _apiBaseUrlDefine
      : kIsWeb
      ? '${Uri.base.origin}/api'
      : 'http://10.0.2.2:3000/api';

  static const String _apiBaseUrlDefine = String.fromEnvironment(
    'API_BASE_URL',
  );

  /// Socket.IO origin. The backend mounts Socket.IO on the same server as the
  /// API, so this is the API URL without the `/api` path. Same defaults as
  /// [apiBaseUrl].
  static String get socketUrl => _socketUrlDefine.isNotEmpty
      ? _socketUrlDefine
      : kIsWeb
      ? Uri.base.origin
      : 'http://10.0.2.2:3000';

  static const String _socketUrlDefine = String.fromEnvironment('SOCKET_URL');

  /// Needed only once calling ships (Phase 2). Empty is valid until then.
  static const String agoraAppId = String.fromEnvironment('AGORA_APP_ID');

  /// Network timeouts. Indian mobile networks are the target, so these are
  /// deliberately more forgiving than a desktop default.
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 20);

  /// Verbose HTTP logging. Forced off in production regardless of the define,
  /// so a release build can never log request bodies.
  static bool get enableHttpLogging =>
      !isProduction &&
      const bool.fromEnvironment('HTTP_LOGGING', defaultValue: true);

  /// Lets QA reach placeholder actions that are not real yet. Always false in
  /// production so a shipped build cannot surface a "Phase 2" message.
  static bool get showDevPlaceholders => !isProduction;
}
