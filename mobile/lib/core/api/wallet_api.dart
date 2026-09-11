import '../../shared/models/wallet.dart';
import 'api_client.dart';

class WalletApi {
  const WalletApi(this._client);

  final ApiClient _client;

  /// `GET /wallet` — current balance plus affordable minutes at today's rates.
  Future<WalletBalance> balance() {
    return _client.request(
      () => _client.dio.get<dynamic>('/wallet'),
      (data) => WalletBalance.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `GET /wallet/ledger`.
  Future<LedgerPage> ledger({int limit = 50, int? before}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/wallet/ledger',
        queryParameters: {'limit': limit, if (before != null) 'before': before},
      ),
      (data) => LedgerPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /wallet/topup` — creates a gateway order. Credits nothing by
  /// itself; only the signed webhook does that.
  Future<TopupOrder> createOrder(String packId) {
    return _client.request(
      () => _client.dio.post<dynamic>('/wallet/topup', data: {'packId': packId}),
      (data) => TopupOrder.fromJson(
        Map<String, dynamic>.from((data as Map)['order'] as Map),
      ),
    );
  }

  /// Simulates the payment gateway's webhook callback — DEVELOPMENT ONLY.
  ///
  /// The backend's mock provider (`PAYMENT_PROVIDER=mock`) accepts an
  /// unsigned webhook outside production (`payment.gateway.js::verifyWebhook`
  /// returns `!env.isProduction` for 'mock'), which is what makes local
  /// top-up testing possible without a real gateway. In production the same
  /// call is refused server-side regardless of what the client sends — this
  /// method exists at all only so a non-production build can exercise the
  /// full topup -> credited-balance path; callers must additionally gate it
  /// behind `Env.isDevelopment` so a release build never shows the option.
  Future<int> devConfirmOrder({
    required int userId,
    required String packId,
    required String orderId,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/wallet/webhook',
        data: {
          'payload': {
            'payment': {
              'entity': {
                'id': orderId,
                'order_id': orderId,
                'notes': {'userId': userId.toString(), 'packId': packId},
              },
            },
          },
        },
      ),
      (data) => ((data as Map)['balance'] as num?)?.toInt() ?? 0,
    );
  }
}
