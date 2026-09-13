import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/auth_api.dart';
import 'package:moco/core/api/users_api.dart';
import 'package:moco/core/auth/auth_controller.dart';
import 'package:moco/core/auth/auth_state.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/features/profile/account_deletion_controller.dart';
import 'package:moco/shared/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockUsersApi extends Mock implements UsersApi {}

class _MockAuthApi extends Mock implements AuthApi {}

class _FakeStore implements SecureStore {
  String? token = 'jwt';
  @override
  Future<void> clear() async => token = null;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String value) async => token = value;
}

const _user = MocoUser(id: 1, phone: '+919876543210', displayName: 'Rahul');

void main() {
  late _MockUsersApi usersApi;
  late _FakeStore store;
  late AuthController authController;

  setUp(() async {
    usersApi = _MockUsersApi();
    store = _FakeStore();
    SharedPreferences.setMockInitialValues({});
    authController = AuthController(
      authApi: _MockAuthApi(),
      usersApi: usersApi,
      store: store,
      prefs: await AppPreferences.create(),
    );
    when(() => usersApi.me()).thenAnswer((_) async => _user);
    await authController.bootstrap();
  });

  test('a successful deletion clears the session', () async {
    when(() => usersApi.deleteAccount()).thenAnswer((_) async {});

    final controller = AccountDeletionController(usersApi, authController);
    final success = await controller.confirmDeletion();

    expect(success, isTrue);
    expect(controller.state.status, DeletionStatus.done);
    expect(authController.value.status, AuthStatus.unauthenticated);
    expect(authController.value.user, isNull);
    expect(store.token, isNull, reason: 'the local token must be cleared too');
  });

  test('a failed deletion keeps the session intact', () async {
    when(() => usersApi.deleteAccount()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'No internet connection'),
    );

    final controller = AccountDeletionController(usersApi, authController);
    final success = await controller.confirmDeletion();

    expect(success, isFalse);
    expect(controller.state.status, DeletionStatus.idle);
    expect(controller.state.error, isNotNull);
    expect(authController.value.status, AuthStatus.authenticated, reason: 'still signed in');
    expect(store.token, 'jwt');
  });

  test('a second call while deleting is ignored', () async {
    when(() => usersApi.deleteAccount()).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    final controller = AccountDeletionController(usersApi, authController);
    final results = await Future.wait([
      controller.confirmDeletion(),
      controller.confirmDeletion(),
    ]);

    verify(() => usersApi.deleteAccount()).called(1);
    expect(results.where((r) => r).length, 1);
  });
}
