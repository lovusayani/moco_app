import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'api/auth_api.dart';
import 'api/chat_api.dart';
import 'api/config_api.dart';
import 'api/feed_api.dart';
import 'api/listeners_api.dart';
import 'api/notifications_api.dart';
import 'api/payouts_api.dart';
import 'api/safety_api.dart';
import 'api/users_api.dart';
import 'auth/auth_controller.dart';
import 'auth/auth_state.dart';
import 'realtime/socket_service.dart';
import 'storage/secure_store.dart';
import '../shared/models/app_config.dart';

/// Overridden in main() once SharedPreferences has loaded, and in tests with a
/// fake. Reading it un-overridden is a programming error, hence the throw.
final appPreferencesProvider = Provider<AppPreferences>(
  (ref) =>
      throw UnimplementedError('appPreferencesProvider must be overridden'),
);

final secureStoreProvider = Provider<SecureStore>(
  (ref) => FlutterSecureStore(),
);

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(store: ref.watch(secureStoreProvider)),
);

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);
final usersApiProvider = Provider<UsersApi>(
  (ref) => UsersApi(ref.watch(apiClientProvider)),
);
final listenersApiProvider = Provider<ListenersApi>(
  (ref) => ListenersApi(ref.watch(apiClientProvider)),
);
final configApiProvider = Provider<ConfigApi>(
  (ref) => ConfigApi(ref.watch(apiClientProvider)),
);
final chatApiProvider = Provider<ChatApi>(
  (ref) => ChatApi(ref.watch(apiClientProvider)),
);
final feedApiProvider = Provider<FeedApi>(
  (ref) => FeedApi(ref.watch(apiClientProvider)),
);
final safetyApiProvider = Provider<SafetyApi>(
  (ref) => SafetyApi(ref.watch(apiClientProvider)),
);
final payoutsApiProvider = Provider<PayoutsApi>(
  (ref) => PayoutsApi(ref.watch(apiClientProvider)),
);
final notificationsApiProvider = Provider<NotificationsApi>(
  (ref) => NotificationsApi(ref.watch(apiClientProvider)),
);

/// Bridges the ValueNotifier-based controller into Riverpod.
///
/// The controller is a plain ValueNotifier so go_router can use it directly as
/// a `refreshListenable`, which is what keeps redirects in sync with auth
/// without a second subscription.
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this.controller) : super(controller.value) {
    controller.addListener(_sync);
  }

  final AuthController controller;

  void _sync() => state = controller.value;

  Future<void> bootstrap() => controller.bootstrap();
  Future<void> signOut() => controller.signOut();
  Future<void> handleUnauthorized() => controller.handleUnauthorized();

  @override
  void dispose() {
    controller.removeListener(_sync);
    super.dispose();
  }
}

final authControllerProvider = StateNotifierProvider<AuthNotifier, AuthState>((
  ref,
) {
  final controller = AuthController(
    authApi: ref.watch(authApiProvider),
    usersApi: ref.watch(usersApiProvider),
    store: ref.watch(secureStoreProvider),
    prefs: ref.watch(appPreferencesProvider),
  );

  // Close the loop here rather than in the client's constructor: one rejected
  // session now clears auth state everywhere, without the two providers
  // depending on each other.
  ref.read(apiClientProvider).onUnauthorized = controller.handleUnauthorized;

  ref.onDispose(controller.dispose);
  return AuthNotifier(controller);
});

/// Raw controller, for screens that need to call actions rather than read state.
final authActionsProvider = Provider<AuthController>(
  (ref) => ref.watch(authControllerProvider.notifier).controller,
);

final socketServiceProvider = Provider<SocketService>((ref) {
  final service = SocketService();
  ref.onDispose(service.dispose);
  return service;
});

/// Server-published rates, packs and languages.
///
/// Kept as a provider rather than copied into local constants so the client can
/// never disagree with the backend about pricing.
final appConfigProvider = FutureProvider<AppConfig>(
  (ref) => ref.watch(configApiProvider).fetch(),
);
