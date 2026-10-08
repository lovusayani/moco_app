import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/users_api.dart';
import '../routing/app_router.dart';

/// Push notifications (Firebase Cloud Messaging) — Android only.
///
/// The server sends every push with a tray notification, so Android shows it
/// by itself while the app is in the background or not running. This class
/// covers the rest:
///
/// * the device token: registered after sign-in, re-registered when FCM
///   rotates it, unregistered on sign-out (so a signed-out phone gets nothing);
/// * the Android 13+ notification permission prompt;
/// * showing a push that arrives while the app is open;
/// * opening the right screen when a notification is tapped, whether the app
///   was open, in the background or not running.
///
/// Without Firebase configuration (no google-services.json in the build, or
/// on the web) every method is a no-op, so the rest of the app never has to
/// check.
class PushService {
  // A named parameter may not be a private name, so no initializing formal.
  // ignore: prefer_initializing_formals
  PushService({required UsersApi usersApi}) : _usersApi = usersApi;

  final UsersApi _usersApi;

  static bool _firebaseReady = false;

  /// Android notification channels. The server targets the same ids.
  static const callsChannel = AndroidNotificationChannel(
    'moco_calls',
    'Calls',
    description: 'Incoming calls',
    importance: Importance.max,
  );
  static const generalChannel = AndroidNotificationChannel(
    'moco_general',
    'Notifications',
    description: 'Payouts, verification and other account updates',
    importance: Importance.high,
  );

  final _local = FlutterLocalNotificationsPlugin();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String? _registeredToken;
  bool _signedIn = false;
  bool _started = false;

  /// Starts Firebase. Called once from main() before the app runs; failure
  /// (no Firebase config in this build) leaves push disabled.
  static Future<void> initializeFirebase() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
    } catch (e) {
      debugPrint('push disabled: Firebase is not configured ($e)');
    }
  }

  bool get isEnabled => _firebaseReady;

  /// The in-app location a notification of [type] opens, or null to just
  /// bring the app forward. An incoming call needs no navigation: if it is
  /// still ringing, the realtime connection delivers it as soon as the app
  /// is open and the call screen takes over.
  static String? locationFor(String? type) => switch (type) {
    'incoming_call' => null,
    'payout_paid' ||
    'payout_approved' ||
    'payout_rejected' => Routes.earningsLedger,
    _ => Routes.notifications,
  };

  /// Wires notification taps to [open] and starts listening. Idempotent.
  Future<void> start({required void Function(String location) open}) async {
    if (!_firebaseReady || _started) return;
    _started = true;

    final android = _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(callsChannel);
    await android?.createNotificationChannel(generalChannel);

    void openType(String? type) {
      final location = locationFor(type);
      if (location != null) open(location);
    }

    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      // A tap on a notification this class showed while the app was open.
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          openType((jsonDecode(payload) as Map)['type'] as String?);
        } catch (_) {
          openType(null);
        }
      },
    );

    final messaging = FirebaseMessaging.instance;

    // Tapped while the app was in the background.
    _subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => openType(message.data['type'] as String?),
      ),
    );

    // Arrived while the app is open: Android does not show it, so we do.
    _subscriptions.add(FirebaseMessaging.onMessage.listen(_showForeground));

    // FCM rotated the token.
    _subscriptions.add(
      messaging.onTokenRefresh.listen((token) {
        if (_signedIn) unawaited(_register(token));
      }),
    );

    // Tapped while the app was not running at all: this launch came from it.
    final initial = await messaging.getInitialMessage();
    if (initial != null) openType(initial.data['type'] as String?);
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final type = message.data['type'] as String?;
    // The realtime connection is already showing the incoming-call screen.
    if (type == 'incoming_call') return;
    final title =
        message.notification?.title ?? message.data['title'] as String?;
    final body = message.notification?.body ?? message.data['body'] as String?;
    if (title == null && body == null) return;
    await _local.show(
      id:
          message.messageId?.hashCode ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          generalChannel.id,
          generalChannel.name,
          channelDescription: generalChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode({'type': type}),
    );
  }

  /// After sign-in (or a restored session): ask for the notification
  /// permission if Android needs it, then register this device's token.
  Future<void> onSignedIn() async {
    _signedIn = true;
    if (!_firebaseReady) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        // Still register: the user can allow notifications later in Android
        // settings, and pushes start arriving without signing in again.
        debugPrint('push: notification permission denied');
      }
      final token = await messaging.getToken();
      if (token != null) await _register(token);
    } catch (e) {
      debugPrint('push: token registration failed ($e)');
    }
  }

  Future<void> _register(String token) async {
    if (token == _registeredToken) return;
    await _usersApi.registerPushToken(token);
    _registeredToken = token;
  }

  /// Before the session is cleared: forget this device on the server and
  /// drop its token, so the next account on this phone starts clean.
  Future<void> onSigningOut() async {
    _signedIn = false;
    if (!_firebaseReady) return;
    final token = _registeredToken;
    _registeredToken = null;
    try {
      if (token != null) await _usersApi.unregisterPushToken(token);
    } catch (e) {
      debugPrint('push: unregister failed ($e)');
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('push: deleteToken failed ($e)');
    }
  }

  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
  }
}
