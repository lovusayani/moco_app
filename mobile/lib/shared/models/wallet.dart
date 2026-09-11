/// Wallet domain models, mirroring `GET /api/wallet`, `GET /api/wallet/ledger`
/// and `POST /api/wallet/topup` exactly. The balance is never computed
/// client-side — every figure here is read straight from the response.
library;

/// `GET /api/wallet`.
class WalletBalance {
  const WalletBalance({
    required this.coinBalance,
    required this.audioMinutes,
    required this.videoMinutes,
  });

  final int coinBalance;
  final int audioMinutes;
  final int videoMinutes;

  factory WalletBalance.fromJson(Map<String, dynamic> json) {
    return WalletBalance(
      coinBalance: (json['coinBalance'] as num?)?.toInt() ?? 0,
      audioMinutes: (json['audioMinutes'] as num?)?.toInt() ?? 0,
      videoMinutes: (json['videoMinutes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One row of `GET /api/wallet/ledger`.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.delta,
    required this.reason,
    this.refId,
    required this.balanceAfter,
    required this.createdAt,
  });

  final int id;

  /// Positive for a credit (topup, bonus, refund), negative for a debit
  /// (call_debit) — the sign alone is enough to render without branching on
  /// `reason` for that.
  final int delta;
  final String reason;
  final String? refId;
  final int balanceAfter;
  final DateTime? createdAt;

  bool get isCredit => delta > 0;

  factory LedgerEntry.fromJson(Map<String, dynamic> json) {
    return LedgerEntry(
      id: (json['id'] as num).toInt(),
      delta: (json['delta'] as num?)?.toInt() ?? 0,
      reason: json['reason'] as String? ?? '',
      refId: json['refId'] as String?,
      balanceAfter: (json['balanceAfter'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }

  /// Label for a reason code the backend didn't write end-user copy for.
  String get label => switch (reason) {
    'topup' => 'Coins purchased',
    'call_debit' => 'Call',
    'refund' => 'Refund',
    'bonus' => 'Bonus',
    _ => reason,
  };
}

/// One page of the ledger.
class LedgerPage {
  const LedgerPage({this.entries = const [], this.nextCursor});

  final List<LedgerEntry> entries;
  final int? nextCursor;

  bool get hasMore => nextCursor != null;

  factory LedgerPage.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    return LedgerPage(
      entries: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      nextCursor: (json['nextCursor'] as num?)?.toInt(),
    );
  }
}

/// The gateway order returned by `POST /api/wallet/topup`. Coins are NOT
/// credited yet at this point — only the webhook credits, per docs/API.md.
class TopupOrder {
  const TopupOrder({
    required this.orderId,
    required this.amount,
    required this.currency,
    required this.provider,
    this.keyId,
  });

  final String orderId;
  final int amount;
  final String currency;
  final String provider;
  final String? keyId;

  factory TopupOrder.fromJson(Map<String, dynamic> json) {
    return TopupOrder(
      orderId: json['orderId'] as String? ?? '',
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      currency: json['currency'] as String? ?? 'INR',
      provider: json['provider'] as String? ?? '',
      keyId: json['keyId'] as String?,
    );
  }
}
