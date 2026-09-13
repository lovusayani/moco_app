import 'api_client.dart';

/// Result of `POST /purchases/google/verify`.
class PurchaseVerification {
  const PurchaseVerification({
    required this.coinBalance,
    required this.coinsGranted,
    required this.alreadyProcessed,
  });

  final int coinBalance;
  final int coinsGranted;
  final bool alreadyProcessed;

  factory PurchaseVerification.fromJson(Map<String, dynamic> json) {
    return PurchaseVerification(
      coinBalance: (json['coinBalance'] as num?)?.toInt() ?? 0,
      coinsGranted: (json['coinsGranted'] as num?)?.toInt() ?? 0,
      alreadyProcessed: json['alreadyProcessed'] as bool? ?? false,
    );
  }
}

/// Google Play purchase verification, against `/api/purchases`.
///
/// This is the ONLY thing the client sends after a Play purchase — a product
/// id and a purchase token. It never sends a coin amount, and the wallet is
/// never credited client-side; [PurchaseVerification.coinBalance] is the
/// server's own post-credit figure.
class PurchasesApi {
  const PurchasesApi(this._client);

  final ApiClient _client;

  Future<PurchaseVerification> verifyGooglePlayPurchase({
    required String productId,
    required String purchaseToken,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/purchases/google/verify',
        data: {'productId': productId, 'purchaseToken': purchaseToken},
      ),
      (data) => PurchaseVerification.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}
