import 'package:in_app_purchase/in_app_purchase.dart';

/// One purchase update, reduced to what [GooglePlayBillingProvider] actually
/// needs — decoupled from `in_app_purchase`'s own type so the provider's
/// state machine can be tested against a fake stream without the plugin's
/// platform channel.
class BillingPurchaseUpdate {
  const BillingPurchaseUpdate({
    required this.productId,
    required this.status,
    this.purchaseToken,
    this.errorMessage,
    this.pendingCompletePurchase = false,
  });

  final String productId;
  final BillingPurchaseStatus status;
  final String? purchaseToken;
  final String? errorMessage;

  /// True if the platform is still waiting for [GooglePlayBillingClient
  /// .completePurchase] — acknowledging/consuming it. A provider must call
  /// that for every terminal update it receives, success or failure, or Play
  /// will refund the purchase after a few days.
  final bool pendingCompletePurchase;
}

enum BillingPurchaseStatus { pending, purchased, error, canceled, restored }

/// Thin seam over `package:in_app_purchase`, the same reason
/// `FeedVideoPlayback` wraps `video_player`: every call this makes is a
/// platform channel, unavailable in a widget/unit test, so the actual
/// purchase state machine (in [GooglePlayBillingProvider]) lives behind an
/// interface a test can fake.
abstract class GooglePlayBillingClient {
  Future<bool> isAvailable();

  /// Looks up store-side product details (price, title) for the given ids.
  /// Ids that Play does not recognise are silently omitted, never thrown for.
  Future<List<String>> queryAvailableProductIds(Set<String> productIds);

  /// Starts a consumable purchase flow. The actual result arrives later on
  /// [purchaseStream] — Play Billing is asynchronous by design (a payment
  /// method might need the user to leave the app).
  Future<void> buyConsumable(String productId);

  /// Acknowledges/consumes a purchase so it can be bought again and so Play
  /// does not treat it as abandoned and refund it.
  Future<void> completePurchase(String productId);

  Stream<List<BillingPurchaseUpdate>> get purchaseStream;

  void dispose();
}

class _RealGooglePlayBillingClient implements GooglePlayBillingClient {
  final InAppPurchase _iap = InAppPurchase.instance;
  final Map<String, PurchaseDetails> _pendingByProductId = {};

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<List<String>> queryAvailableProductIds(Set<String> productIds) async {
    final response = await _iap.queryProductDetails(productIds);
    return response.productDetails.map((d) => d.id).toList();
  }

  @override
  Future<void> buyConsumable(String productId) async {
    final response = await _iap.queryProductDetails({productId});
    final details = response.productDetails.firstOrNull;
    if (details == null) {
      throw StateError('Play does not recognise product $productId');
    }
    await _iap.buyConsumable(
      purchaseParam: PurchaseParam(productDetails: details),
    );
  }

  @override
  Future<void> completePurchase(String productId) async {
    final purchase = _pendingByProductId.remove(productId);
    if (purchase != null && purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }

  @override
  Stream<List<BillingPurchaseUpdate>> get purchaseStream {
    return _iap.purchaseStream.map((purchases) {
      return purchases.map((p) {
        _pendingByProductId[p.productID] = p;
        return BillingPurchaseUpdate(
          productId: p.productID,
          status: switch (p.status) {
            PurchaseStatus.pending => BillingPurchaseStatus.pending,
            PurchaseStatus.purchased => BillingPurchaseStatus.purchased,
            PurchaseStatus.restored => BillingPurchaseStatus.restored,
            PurchaseStatus.error => BillingPurchaseStatus.error,
            PurchaseStatus.canceled => BillingPurchaseStatus.canceled,
          },
          purchaseToken: p.verificationData.serverVerificationData,
          errorMessage: p.error?.message,
          pendingCompletePurchase: p.pendingCompletePurchase,
        );
      }).toList();
    });
  }

  @override
  void dispose() {}
}

GooglePlayBillingClient createGooglePlayBillingClient() => _RealGooglePlayBillingClient();

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
