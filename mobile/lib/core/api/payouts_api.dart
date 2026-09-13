import '../../shared/models/earnings.dart';
import 'api_client.dart';

/// Listener earnings and withdrawals, against the existing `/api/payouts`
/// endpoints. All figures are server-derived; nothing here computes a balance.
class PayoutsApi {
  const PayoutsApi(this._client);

  final ApiClient _client;

  /// `GET /payouts/earnings`.
  Future<EarningsSummary> earnings() {
    return _client.request(
      () => _client.dio.get<dynamic>('/payouts/earnings'),
      (data) => EarningsSummary.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `GET /payouts/earnings/ledger`.
  Future<EarningsLedgerPage> earningsLedger({int limit = 50, int? before}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/payouts/earnings/ledger',
        queryParameters: {'limit': limit, if (before != null) 'before': before},
      ),
      (data) => EarningsLedgerPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /payouts` — requests a withdrawal. Does not debit; the payout
  /// worker debits once an admin approves.
  Future<Payout> requestPayout(int amount) {
    return _client.request(
      () => _client.dio.post<dynamic>('/payouts', data: {'amount': amount}),
      (data) => Payout(
        id: ((data as Map)['payoutId'] as num).toInt(),
        amount: (data['amount'] as num?)?.toInt() ?? amount,
        status: data['status'] as String? ?? 'requested',
        createdAt: DateTime.tryParse(data['createdAt'] as String? ?? ''),
      ),
    );
  }

  /// `GET /payouts` — withdrawal history.
  Future<List<Payout>> payouts() {
    return _client.request(
      () => _client.dio.get<dynamic>('/payouts'),
      (data) {
        final raw = (data as Map)['payouts'];
        return raw is List
            ? raw.whereType<Map>().map((e) => Payout.fromJson(Map<String, dynamic>.from(e))).toList()
            : const <Payout>[];
      },
    );
  }
}
