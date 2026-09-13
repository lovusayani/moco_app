import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/purchases_api.dart';
import '../../core/api/wallet_api.dart';
import '../../core/config/env.dart';
import '../../core/errors/api_exception.dart';
import '../../core/payments/google_play_billing_client.dart';
import '../../core/payments/purchase_provider.dart';
import '../../core/providers.dart';
import '../../shared/models/app_config.dart';
import '../../shared/models/wallet.dart';

class WalletState {
  const WalletState({
    this.balance,
    this.isLoading = true,
    this.error,
    this.purchasingPackId,
    this.lastPurchaseError,
  });

  final WalletBalance? balance;
  final bool isLoading;
  final ApiException? error;

  /// The pack currently being purchased, so a second tap on any pack — not
  /// just the same one — is ignored while a purchase is in flight.
  final String? purchasingPackId;
  final ApiException? lastPurchaseError;

  bool get isPurchasing => purchasingPackId != null;

  WalletState copyWith({
    WalletBalance? balance,
    bool? isLoading,
    ApiException? error,
    String? purchasingPackId,
    ApiException? lastPurchaseError,
    bool clearError = false,
    bool clearPurchasing = false,
    bool clearLastPurchaseError = false,
  }) {
    return WalletState(
      balance: balance ?? this.balance,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      purchasingPackId: clearPurchasing ? null : (purchasingPackId ?? this.purchasingPackId),
      lastPurchaseError: clearLastPurchaseError ? null : (lastPurchaseError ?? this.lastPurchaseError),
    );
  }
}

class WalletController extends StateNotifier<WalletState> {
  WalletController(this._api, this._provider, this._refreshUser)
    : super(const WalletState()) {
    load();
  }

  final WalletApi _api;
  final PurchaseProvider _provider;
  final Future<void> Function() _refreshUser;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final balance = await _api.balance();
      state = state.copyWith(balance: balance, isLoading: false);
    } on ApiException catch (e) {
      state = state.copyWith(error: e, isLoading: false);
    }
  }

  Future<void> purchase(CoinPack pack) async {
    if (state.isPurchasing) return;
    state = state.copyWith(purchasingPackId: pack.id, clearLastPurchaseError: true);

    final result = await _provider.purchase(pack);

    if (result.isSuccess) {
      // Re-read from the server rather than trust the webhook's own number a
      // second time — the wallet screen must always show what GET /wallet
      // says, not a value carried over from the purchase call.
      await load();
      await _refreshUser();
      state = state.copyWith(clearPurchasing: true);
    } else {
      state = state.copyWith(
        clearPurchasing: true,
        lastPurchaseError: result.error,
      );
    }
  }
}

final walletApiProvider = Provider<WalletApi>(
  (ref) => WalletApi(ref.watch(apiClientProvider)),
);

final purchasesApiProvider = Provider<PurchasesApi>(
  (ref) => PurchasesApi(ref.watch(apiClientProvider)),
);

/// The billing client, created once per app run — a real
/// `InAppPurchase.instance` connection is not something to open per-purchase.
final googlePlayBillingClientProvider = Provider<GooglePlayBillingClient>((ref) {
  final client = createGooglePlayBillingClient();
  ref.onDispose(client.dispose);
  return client;
});

/// Exactly one of these is ever offered: the mock provider only in
/// development (it exercises the backend's own dev-only unsigned-webhook
/// path), Google Play Billing everywhere else. There is no build
/// configuration in which both — or neither — are considered available,
/// which is what a production build cannot accidentally expose mock credits.
final purchaseProviderProvider = Provider<PurchaseProvider>((ref) {
  if (Env.isDevelopment) {
    final session = ref.watch(authControllerProvider);
    return MockPurchaseProvider(
      ref.watch(walletApiProvider),
      session,
      isDevelopment: true,
    );
  }
  return GooglePlayBillingProvider(
    ref.watch(googlePlayBillingClientProvider),
    ref.watch(purchasesApiProvider),
    isDevelopment: false,
  );
});

final walletControllerProvider =
    StateNotifierProvider<WalletController, WalletState>((ref) {
      return WalletController(
        ref.watch(walletApiProvider),
        ref.watch(purchaseProviderProvider),
        () => ref.read(authActionsProvider).refreshUser(),
      );
    });
