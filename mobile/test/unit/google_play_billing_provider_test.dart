import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/purchases_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/payments/google_play_billing_client.dart';
import 'package:moco/core/payments/purchase_provider.dart';
import 'package:moco/shared/models/app_config.dart';

import '../support/fake_billing_client.dart';

class _MockPurchasesApi extends Mock implements PurchasesApi {}

const _pack = CoinPack(id: 'pack_99', priceInr: 99, coins: 99, bonus: 5);

void main() {
  late FakeGooglePlayBillingClient client;
  late _MockPurchasesApi api;

  setUp(() {
    client = FakeGooglePlayBillingClient();
    api = _MockPurchasesApi();
  });

  GooglePlayBillingProvider subject() =>
      GooglePlayBillingProvider(client, api, isDevelopment: false);

  test('is the production path: available outside development, never in it', () {
    expect(
      GooglePlayBillingProvider(client, api, isDevelopment: false).isAvailable,
      isTrue,
    );
    expect(
      GooglePlayBillingProvider(client, api, isDevelopment: true).isAvailable,
      isFalse,
    );
  });

  test('unavailable on the device fails without starting a purchase', () async {
    client.available = false;

    final result = await subject().purchase(_pack);

    expect(result.isSuccess, isFalse);
    expect(client.buyCallCount, 0);
  });

  test('a successful purchase verifies with the backend and returns its balance', () async {
    when(
      () => api.verifyGooglePlayPurchase(productId: 'pack_99', purchaseToken: 'tok-1'),
    ).thenAnswer(
      (_) async => const PurchaseVerification(
        coinBalance: 250,
        coinsGranted: 104,
        alreadyProcessed: false,
      ),
    );

    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: 'tok-1',
        pendingCompletePurchase: true,
      ),
    );
    final result = await future;

    expect(result.isSuccess, isTrue);
    expect(result.coinBalance, 250);
    expect(client.completeCallCount, 1, reason: 'Play must be acknowledged');
    expect(client.lastCompletedProductId, 'pack_99');
  });

  test('an update for a different product is ignored', () async {
    when(
      () => api.verifyGooglePlayPurchase(productId: 'pack_99', purchaseToken: 'tok-1'),
    ).thenAnswer(
      (_) async => const PurchaseVerification(
        coinBalance: 10,
        coinsGranted: 10,
        alreadyProcessed: false,
      ),
    );

    final future = subject().purchase(_pack);
    // A stray update for some other in-flight pack must not resolve this one.
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_299',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: 'other-token',
      ),
    );
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: 'tok-1',
      ),
    );
    final result = await future;

    expect(result.coinBalance, 10);
    verifyNever(
      () => api.verifyGooglePlayPurchase(productId: 'pack_299', purchaseToken: any(named: 'purchaseToken')),
    );
  });

  test('cancellation is a failure, and still acknowledges Play', () async {
    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.canceled,
        pendingCompletePurchase: true,
      ),
    );
    final result = await future;

    expect(result.isSuccess, isFalse);
    expect(client.completeCallCount, 1);
    verifyNever(
      () => api.verifyGooglePlayPurchase(
        productId: any(named: 'productId'),
        purchaseToken: any(named: 'purchaseToken'),
      ),
    );
  });

  test('a platform error is a failure with the platform message', () async {
    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.error,
        errorMessage: 'Payment declined',
        pendingCompletePurchase: true,
      ),
    );
    final result = await future;

    expect(result.isSuccess, isFalse);
    expect(result.error?.message, 'Payment declined');
  });

  test('a backend rejection is a failure, but Play is still acknowledged', () async {
    when(
      () => api.verifyGooglePlayPurchase(productId: 'pack_99', purchaseToken: 'tok-1'),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        code: 'invalid_purchase',
        message: 'Google Play did not confirm this purchase',
      ),
    );

    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: 'tok-1',
        pendingCompletePurchase: true,
      ),
    );
    final result = await future;

    expect(result.isSuccess, isFalse);
    expect(result.error?.code, 'invalid_purchase');
    // Not left stuck pending on the Play side just because the backend
    // rejected it.
    expect(client.completeCallCount, 1);
  });

  test('a duplicate/already-processed purchase still succeeds honestly', () async {
    when(
      () => api.verifyGooglePlayPurchase(productId: 'pack_99', purchaseToken: 'tok-1'),
    ).thenAnswer(
      (_) async => const PurchaseVerification(
        coinBalance: 250,
        coinsGranted: 0,
        alreadyProcessed: true,
      ),
    );

    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: 'tok-1',
      ),
    );
    final result = await future;

    expect(result.isSuccess, isTrue);
    expect(result.coinBalance, 250);
  });

  test('a purchase with no verification token fails without calling the backend', () async {
    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: null,
      ),
    );
    final result = await future;

    expect(result.isSuccess, isFalse);
    verifyNever(
      () => api.verifyGooglePlayPurchase(
        productId: any(named: 'productId'),
        purchaseToken: any(named: 'purchaseToken'),
      ),
    );
  });

  test('a failure to start the purchase resolves as a failure', () async {
    client.buyError = Exception('billing unavailable');

    final result = await subject().purchase(_pack);

    expect(result.isSuccess, isFalse);
  });

  test('a pending update alone never resolves the purchase', () async {
    final future = subject().purchase(_pack);
    client.emit(
      const BillingPurchaseUpdate(productId: 'pack_99', status: BillingPurchaseStatus.pending),
    );

    // Give the pending update a chance to (wrongly) resolve the future.
    var resolved = false;
    // ignore: unawaited_futures
    future.then((_) => resolved = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resolved, isFalse);

    // Clean up: complete it for real so the test doesn't leak a pending future.
    when(
      () => api.verifyGooglePlayPurchase(productId: 'pack_99', purchaseToken: 'tok-1'),
    ).thenAnswer(
      (_) async => const PurchaseVerification(
        coinBalance: 5,
        coinsGranted: 5,
        alreadyProcessed: false,
      ),
    );
    client.emit(
      const BillingPurchaseUpdate(
        productId: 'pack_99',
        status: BillingPurchaseStatus.purchased,
        purchaseToken: 'tok-1',
      ),
    );
    await future;
  });
}
