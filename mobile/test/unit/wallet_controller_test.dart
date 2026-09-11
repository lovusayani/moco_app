import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/wallet_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/payments/purchase_provider.dart';
import 'package:moco/features/wallet/wallet_controller.dart';
import 'package:moco/shared/models/app_config.dart';
import 'package:moco/shared/models/wallet.dart';

class _MockWalletApi extends Mock implements WalletApi {}

class _MockPurchaseProvider extends Mock implements PurchaseProvider {}

const _pack = CoinPack(id: 'pack_99', priceInr: 99, coins: 99, bonus: 5);

void main() {
  setUpAll(() => registerFallbackValue(_pack));

  late _MockWalletApi api;
  late _MockPurchaseProvider provider;
  late int refreshCount;

  WalletController buildController() {
    return WalletController(api, provider, () async {
      refreshCount += 1;
    });
  }

  setUp(() {
    api = _MockWalletApi();
    provider = _MockPurchaseProvider();
    refreshCount = 0;
    when(() => api.balance()).thenAnswer(
      (_) async => const WalletBalance(coinBalance: 45, audioMinutes: 7, videoMinutes: 3),
    );
  });

  test('load() populates balance from the server', () async {
    final controller = buildController();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.balance?.coinBalance, 45);
    expect(controller.state.isLoading, isFalse);
    expect(controller.state.error, isNull);
  });

  test('load() surfaces a failure without touching the previous balance', () async {
    final controller = buildController();
    await Future<void>.delayed(Duration.zero);

    when(() => api.balance()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );
    await controller.load();

    expect(controller.state.error, isNotNull);
    expect(controller.state.balance?.coinBalance, 45, reason: 'stale data beats no data');
  });

  test('a successful purchase reloads the balance and refreshes the user', () async {
    when(() => provider.purchase(_pack)).thenAnswer(
      (_) async => const PurchaseResult.success(139),
    );
    final controller = buildController();
    await Future<void>.delayed(Duration.zero);

    when(() => api.balance()).thenAnswer(
      (_) async => const WalletBalance(coinBalance: 139, audioMinutes: 23, videoMinutes: 11),
    );
    await controller.purchase(_pack);

    expect(controller.state.balance?.coinBalance, 139);
    expect(controller.state.isPurchasing, isFalse);
    expect(controller.state.lastPurchaseError, isNull);
    expect(refreshCount, 1);
  });

  test('a failed purchase records the error without touching the balance', () async {
    when(() => provider.purchase(_pack)).thenAnswer(
      (_) async => const PurchaseResult.failure(
        ApiException(kind: ApiErrorKind.validation, message: 'bad pack'),
      ),
    );
    final controller = buildController();
    await Future<void>.delayed(Duration.zero);

    await controller.purchase(_pack);

    expect(controller.state.lastPurchaseError, isNotNull);
    expect(controller.state.balance?.coinBalance, 45, reason: 'unchanged on failure');
    expect(controller.state.isPurchasing, isFalse);
    expect(refreshCount, 0, reason: 'never refresh the user on a failed purchase');
  });

  test('a second purchase tap is ignored while one is already in flight', () async {
    final gate = Completer<PurchaseResult>();
    when(() => provider.purchase(_pack)).thenAnswer((_) => gate.future);
    final controller = buildController();
    await Future<void>.delayed(Duration.zero);

    final first = controller.purchase(_pack);
    final second = controller.purchase(_pack); // should be a no-op: still busy

    gate.complete(const PurchaseResult.success(50));
    await first;
    await second;

    verify(() => provider.purchase(_pack)).called(1);
  });
}
