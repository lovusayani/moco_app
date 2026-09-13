import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/notifications_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/auth/auth_controller.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/shared/models/notification.dart';
import 'package:moco/shared/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory token store, so tests never touch the platform keystore.
class FakeSecureStore implements SecureStore {
  FakeSecureStore([this.token]);

  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}

/// Base overrides every screen test needs.
///
/// Screens watch the auth controller, which depends on preferences and the
/// token store, so without these any widget test fails on an unimplemented
/// provider rather than on the behaviour under test.
Future<List<Override>> baseOverrides({FakeSecureStore? store}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await AppPreferences.create();
  return [
    appPreferencesProvider.overrideWithValue(prefs),
    secureStoreProvider.overrideWithValue(store ?? FakeSecureStore()),
    // Discovery's header watches the notifications inbox for its unread
    // badge. Without this override that provider would fall through to a
    // real, unmocked ApiClient and — if a local dev server happens to be
    // running on the machine — send it a genuine network request from a
    // widget test. An empty inbox is a safe, silent default for every test
    // that does not care about notifications specifically.
    notificationsApiProvider.overrideWithValue(_EmptyNotificationsApi()),
  ];
}

class _EmptyNotificationsApi implements NotificationsApi {
  @override
  Future<NotificationPage> list({int limit = 30, int? before}) async =>
      const NotificationPage();

  @override
  Future<void> markRead(int id) async {}

  @override
  Future<void> markAllRead() async {}

  @override
  Future<void> delete(int id) async {}
}

/// [baseOverrides] plus a fully bootstrapped, signed-in session.
///
/// Several Phase 5+ screens (Profile, its sub-screens) read
/// `authControllerProvider` directly rather than fetching their own copy of
/// the user, since the signed-in user is already the single source of truth
/// app-wide. Those screens need a real, bootstrapped [AuthNotifier] rather
/// than the default uninitialized one — this drives an actual `bootstrap()`
/// against a mocked [UsersApi] so the resulting state is exactly what the
/// real app would have produced from a stored token.
Future<List<Override>> signedInOverrides({
  required MocoUser user,
  UsersApi? usersApi,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await AppPreferences.create();
  final store = FakeSecureStore('jwt');

  final api = usersApi ?? _StubUsersApi(user);
  final controller = AuthController(
    authApi: _NoopAuthApi(),
    usersApi: api,
    store: store,
    prefs: prefs,
  );
  await controller.bootstrap();

  return [
    appPreferencesProvider.overrideWithValue(prefs),
    secureStoreProvider.overrideWithValue(store),
    usersApiProvider.overrideWithValue(api),
    authControllerProvider.overrideWith((ref) => AuthNotifier(controller)),
    notificationsApiProvider.overrideWithValue(_EmptyNotificationsApi()),
  ];
}

/// Returns [user] from `/users/me`, which is all [AuthController.bootstrap]
/// needs. Individual tests override [usersApiProvider] again afterward when
/// they need to assert on a specific call (e.g. `updateProfile`).
class _StubUsersApi implements UsersApi {
  _StubUsersApi(this._user);
  final MocoUser _user;

  @override
  Future<MocoUser> me() async => _user;

  @override
  Future<MocoUser> updateProfile({
    String? displayName,
    String? avatarUrl,
    String? language,
    String? gender,
  }) async => _user;

  @override
  Future<Map<String, dynamic>> becomeListener() async => {};

  @override
  Future<void> registerPushToken(String token) async {}

  @override
  Future<void> deleteAccount() async {}
}

/// Never called in a signed-in-session test, but AuthController requires one.
class _NoopAuthApi implements AuthApi {
  @override
  Future<int> requestOtp(String phone) => throw UnimplementedError();

  @override
  Future<AuthSession> verifyOtp({required String phone, required String code}) =>
      throw UnimplementedError();
}

/// Wraps a screen that supplies its own Scaffold (onboarding, login, profile
/// setup, listener profile).
Widget wrapWidget(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(theme: MocoTheme.dark, home: child),
  );
}

/// Wraps a screen that lives INSIDE the app shell.
///
/// Discovery is mounted as the ShellRoute's child, so in the real app it always
/// has AppShell's Scaffold — and therefore a Material ancestor — above it. The
/// harness reproduces that rather than testing the screen in a context it never
/// actually renders in.
Widget wrapShellScreen(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: MocoTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

/// Wraps a screen that NAVIGATES with go_router.
///
/// Onboarding calls `context.go` when it finishes, which asserts without a
/// router above it. A minimal two-route router reproduces just enough of the
/// real graph to exercise that.
Widget wrapRoutedScreen(
  Widget child, {
  List<Override> overrides = const [],
  String destination = '/login',
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => child),
      GoRoute(
        path: destination,
        builder: (_, __) => const Scaffold(body: Text('destination')),
      ),
    ],
  );

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(theme: MocoTheme.dark, routerConfig: router),
  );
}
