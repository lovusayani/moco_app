import 'dart:async';

import 'package:moco/core/payments/google_play_billing_client.dart';

/// A [GooglePlayBillingClient] a test can drive directly — emit a purchase
/// update on demand instead of waiting on a real platform channel.
class FakeGooglePlayBillingClient implements GooglePlayBillingClient {
  bool available = true;
  int buyCallCount = 0;
  int completeCallCount = 0;
  String? lastCompletedProductId;
  Object? buyError;

  final _controller = StreamController<List<BillingPurchaseUpdate>>.broadcast();

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<String>> queryAvailableProductIds(Set<String> productIds) async =>
      productIds.toList();

  @override
  Future<void> buyConsumable(String productId) async {
    buyCallCount += 1;
    if (buyError != null) throw buyError!;
  }

  @override
  Future<void> completePurchase(String productId) async {
    completeCallCount += 1;
    lastCompletedProductId = productId;
  }

  @override
  Stream<List<BillingPurchaseUpdate>> get purchaseStream => _controller.stream;

  /// Pushes one update, as the real plugin would after `buyConsumable`.
  void emit(BillingPurchaseUpdate update) {
    _controller.add([update]);
  }

  @override
  void dispose() {
    _controller.close();
  }
}
