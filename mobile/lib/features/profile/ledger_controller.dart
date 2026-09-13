import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/payouts_api.dart';
import '../../core/api/wallet_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/earnings.dart';
import '../../shared/models/wallet.dart';
import '../wallet/wallet_controller.dart' show walletApiProvider;

/// One row, shared by both the coin ledger and the earnings ledger so a
/// single list widget can render either without knowing which backend
/// resource it came from.
class LedgerRow {
  const LedgerRow({
    required this.id,
    required this.label,
    required this.delta,
    required this.balanceAfter,
    required this.createdAt,
  });

  final int id;
  final String label;
  final int delta;
  final int balanceAfter;
  final DateTime? createdAt;

  bool get isCredit => delta > 0;

  factory LedgerRow.fromCoinEntry(LedgerEntry e) => LedgerRow(
    id: e.id,
    label: e.label,
    delta: e.delta,
    balanceAfter: e.balanceAfter,
    createdAt: e.createdAt,
  );

  factory LedgerRow.fromEarningsEntry(EarningsLedgerEntry e) => LedgerRow(
    id: e.id,
    label: e.label,
    delta: e.delta,
    balanceAfter: e.balanceAfter,
    createdAt: e.createdAt,
  );
}

class LedgerState {
  const LedgerState({
    this.rows = const [],
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
  });

  final List<LedgerRow> rows;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final ApiException? error;

  bool get isEmpty => !isLoading && error == null && rows.isEmpty;
  bool get isFatalError => error != null && rows.isEmpty;

  LedgerState copyWith({
    List<LedgerRow>? rows,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    ApiException? error,
    bool clearError = false,
  }) {
    return LedgerState(
      rows: rows ?? this.rows,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Cursor-paginated ledger, generic over which backend resource it reads via
/// an injected page-fetch function. The wallet ledger and the listener
/// earnings ledger both page the same way (`before` cursor, newest first,
/// server-side append-only), so one controller serves both rather than two
/// near-identical copies.
class LedgerController extends StateNotifier<LedgerState> {
  LedgerController(this._fetchPage) : super(const LedgerState()) {
    load();
  }

  /// Returns (rows, nextCursor) for one page.
  final Future<(List<LedgerRow>, int?)> Function({int limit, int? before}) _fetchPage;

  int? _cursor;
  bool _loadingPage = false;

  Future<void> load() async {
    if (_loadingPage) return;
    _loadingPage = true;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final (rows, nextCursor) = await _fetchPage(limit: 30);
      _cursor = nextCursor;
      state = state.copyWith(rows: rows, hasMore: nextCursor != null, isLoading: false);
    } on ApiException catch (e) {
      state = state.copyWith(error: e, isLoading: false);
    } finally {
      _loadingPage = false;
    }
  }

  Future<void> loadMore() async {
    if (_loadingPage || !state.hasMore || state.isLoading) return;
    _loadingPage = true;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final (rows, nextCursor) = await _fetchPage(limit: 30, before: _cursor);
      _cursor = nextCursor;
      final byId = {for (final r in state.rows) r.id: r};
      for (final r in rows) {
        byId[r.id] = r;
      }
      final merged = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));
      state = state.copyWith(rows: merged, hasMore: nextCursor != null, isLoadingMore: false);
    } on ApiException catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e);
    } finally {
      _loadingPage = false;
    }
  }
}

Future<(List<LedgerRow>, int?)> _coinLedgerPage(
  WalletApi api, {
  int limit = 30,
  int? before,
}) async {
  final page = await api.ledger(limit: limit, before: before);
  return (page.entries.map(LedgerRow.fromCoinEntry).toList(), page.nextCursor);
}

Future<(List<LedgerRow>, int?)> _earningsLedgerPage(
  PayoutsApi api, {
  int limit = 30,
  int? before,
}) async {
  final page = await api.earningsLedger(limit: limit, before: before);
  return (page.entries.map(LedgerRow.fromEarningsEntry).toList(), page.nextCursor);
}

final walletLedgerControllerProvider =
    StateNotifierProvider.autoDispose<LedgerController, LedgerState>((ref) {
      final api = ref.watch(walletApiProvider);
      return LedgerController(({limit = 30, before}) => _coinLedgerPage(api, limit: limit, before: before));
    });

final earningsLedgerControllerProvider =
    StateNotifierProvider.autoDispose<LedgerController, LedgerState>((ref) {
      final api = ref.watch(payoutsApiProvider);
      return LedgerController(({limit = 30, before}) => _earningsLedgerPage(api, limit: limit, before: before));
    });
