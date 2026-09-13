/// Listener earnings domain models, mirroring `GET /api/payouts/earnings`,
/// `GET /api/payouts/earnings/ledger` and `POST/GET /api/payouts` exactly.
/// Every figure is read straight from the server — nothing here is computed
/// client-side, the same rule the wallet models follow for coins.
library;

/// `GET /api/payouts/earnings`.
class EarningsSummary {
  const EarningsSummary({
    required this.balance,
    required this.lifetime,
    required this.today,
    required this.thisMonth,
    required this.totalCalls,
    required this.rating,
    this.upiId,
    required this.minWithdrawal,
    required this.canWithdraw,
  });

  final int balance;
  final int lifetime;
  final int today;
  final int thisMonth;
  final int totalCalls;
  final double rating;
  final String? upiId;
  final int minWithdrawal;
  final bool canWithdraw;

  factory EarningsSummary.fromJson(Map<String, dynamic> json) {
    return EarningsSummary(
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      lifetime: (json['lifetime'] as num?)?.toInt() ?? 0,
      today: (json['today'] as num?)?.toInt() ?? 0,
      thisMonth: (json['thisMonth'] as num?)?.toInt() ?? 0,
      totalCalls: (json['totalCalls'] as num?)?.toInt() ?? 0,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      upiId: json['upiId'] as String?,
      minWithdrawal: (json['minWithdrawal'] as num?)?.toInt() ?? 100,
      canWithdraw: json['canWithdraw'] as bool? ?? false,
    );
  }
}

/// One row of `GET /api/payouts/earnings/ledger`.
class EarningsLedgerEntry {
  const EarningsLedgerEntry({
    required this.id,
    required this.delta,
    required this.reason,
    this.refId,
    required this.balanceAfter,
    required this.createdAt,
  });

  final int id;
  final int delta;
  final String reason;
  final String? refId;
  final int balanceAfter;
  final DateTime? createdAt;

  bool get isCredit => delta > 0;

  factory EarningsLedgerEntry.fromJson(Map<String, dynamic> json) {
    return EarningsLedgerEntry(
      id: (json['id'] as num).toInt(),
      delta: (json['delta'] as num?)?.toInt() ?? 0,
      reason: json['reason'] as String? ?? '',
      refId: json['refId'] as String?,
      balanceAfter: (json['balanceAfter'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }

  String get label => switch (reason) {
    'call_credit' => 'Call earning',
    'payout' => 'Withdrawal',
    _ => reason,
  };
}

class EarningsLedgerPage {
  const EarningsLedgerPage({this.entries = const [], this.nextCursor});

  final List<EarningsLedgerEntry> entries;
  final int? nextCursor;

  bool get hasMore => nextCursor != null;

  factory EarningsLedgerPage.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    return EarningsLedgerPage(
      entries: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => EarningsLedgerEntry.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      nextCursor: (json['nextCursor'] as num?)?.toInt(),
    );
  }
}

/// One withdrawal request, from `POST /api/payouts` or `GET /api/payouts`.
class Payout {
  const Payout({
    required this.id,
    required this.amount,
    required this.status,
    this.upiRef,
    this.note,
    required this.createdAt,
    this.processedAt,
  });

  final int id;
  final int amount;
  final String status;
  final String? upiRef;
  final String? note;
  final DateTime? createdAt;
  final DateTime? processedAt;

  factory Payout.fromJson(Map<String, dynamic> json) {
    return Payout(
      id: (json['id'] as num).toInt(),
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? 'requested',
      upiRef: json['upiRef'] as String?,
      note: json['note'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      processedAt: json['processedAt'] == null
          ? null
          : DateTime.tryParse(json['processedAt'] as String),
    );
  }
}
