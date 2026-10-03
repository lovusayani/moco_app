import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the current platform can genuinely do, decided in one place.
///
/// The web build shares every screen with Android, but two native
/// capabilities do not exist there and must not be faked:
///
/// * **Calling.** `agora_rtc_engine`'s web target is an alpha wrapper around
///   the Agora Web SDK that needs an external `iris-web` script, is only
///   tested by Agora on desktop browsers, and returns error -4 for several of
///   the calls [AgoraCallService] makes (speakerphone routing, camera switch).
///   Rather than ship a call path that might connect billing without media,
///   calling is off on web: no call is initiated, accepted, or joined.
/// * **Google Play Billing.** It is an Android store API; there is no web
///   implementation, and the backend verifies Play purchase tokens only.
///
/// Read through [platformCapabilitiesProvider] so widget tests can exercise
/// the web behaviour without running in a browser.
class PlatformCapabilities {
  const PlatformCapabilities({required this.isWeb});

  /// The capabilities of the platform this binary was compiled for.
  static const current = PlatformCapabilities(isWeb: kIsWeb);

  final bool isWeb;

  /// Voice/video calls through Agora (start, answer, and go online as a
  /// listener — going online only makes sense where calls can be answered).
  bool get supportsCalling => !isWeb;

  /// Google Play Billing coin purchases.
  bool get supportsPlayBilling => !isWeb;

  static const callingUnavailableMessage =
      'Voice and video calls are not available on the web app yet. '
      'Use the Moco Android app to call.';

  static const goOnlineUnavailableMessage =
      'Calls can only be answered in the Moco Android app, '
      'so go online from there.';

  static const purchasesUnavailableMessage =
      'Coins can’t be bought on the web app. Buy them in the Moco Android '
      'app — your balance is the same everywhere.';
}

final platformCapabilitiesProvider = Provider<PlatformCapabilities>(
  (ref) => PlatformCapabilities.current,
);
