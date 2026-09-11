import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/wallet_api.dart';
import 'package:moco/core/auth/auth_state.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/payments/purchase_provider.dart';
import 'package:moco/shared/models/app_config.dart';
import 'package:moco/shared/models/user.dart';
import 'package:moco/shared/models/wallet.dart';

class _MockWalletApi extends Mock implements WalletApi {}

const _pack = CoinPack(id: 'pack_49', priceInr: 49, coins: 49, bonus: 0);
const _signedInUser = MocoUser(id: 3, phone: '+919800000001');

void main() {
  late _MockWalletApi api;

  setUp(() => api = _MockWalletApi());

  test('is unavailable outside development, regardless of session', () {
    final provider = MockPurchaseProvider(
      api,
      const AuthState(status: AuthStatus.authenticated, user: _signedInUser),
      isDevelopment: false,
    );
    expect(provider.isAvailable, isFalse);
  });

  test('is available in development when signed in', () {
    final provider = MockPurchaseProvider(
      api,
      const AuthState(status: AuthStatus.authenticated, user: _signedInUser),
      isDevelopment: true,
    );
    expect(provider.isAvailable, isTrue);
  });

  test('fails cleanly with no session rather than sending a null userId', () async {
    final provider = MockPurchaseProvider(
      api,
      const AuthState(status: AuthStatus.unauthenticated),
      isDevelopment: true,
    );

    final result = await provider.purchase(_pack);

    expect(result.isSuccess, isFalse);
    expect(result.error?.kind, ApiErrorKind.unauthorized);
    verifyNever(() => api.createOrder(any()));
  });

  test('creates an order then confirms it with the signed-in user id', () async {
    when(() => api.createOrder('pack_49')).thenAnswer(
      (_) async => const TopupOrder(
        orderId: 'mock_abc123',
        amount: 4900,
        currency: 'INR',
        provider: 'mock',
      ),
    );
    when(
      () => api.devConfirmOrder(userId: 3, packId: 'pack_49', orderId: 'mock_abc123'),
    ).thenAnswer((_) async => 94);

    final provider = MockPurchaseProvider(
      api,
      const AuthState(status: AuthStatus.authenticated, user: _signedInUser),
      isDevelopment: true,
    );

    final result = await provider.purchase(_pack);

    expect(result.isSuccess, isTrue);
    expect(result.coinBalance, 94);
  });

  test('surfaces the backend error rather than throwing', () async {
    when(() => api.createOrder('pack_49')).thenThrow(
      const ApiException(kind: ApiErrorKind.server, message: 'gateway down'),
    );

    final provider = MockPurchaseProvider(
      api,
      const AuthState(status: AuthStatus.authenticated, user: _signedInUser),
      isDevelopment: true,
    );

    final result = await provider.purchase(_pack);

    expect(result.isSuccess, isFalse);
    expect(result.error?.kind, ApiErrorKind.server);
  });
}
