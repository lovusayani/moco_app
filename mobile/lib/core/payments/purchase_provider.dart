// prefer_initializing_formals: `required this._isDevelopment` is invalid for a
// named parameter (private names can't be named parameters).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../api/purchases_api.dart';
import '../api/wallet_api.dart';
import '../auth/auth_state.dart';
import '../errors/api_exception.dart';
import '../../shared/models/app_config.dart';
import 'google_play_billing_client.dart';

/// Outcome of a purchase attempt. `coinBalance` is the server's post-credit
/// balance on success — never a locally-computed total.
class PurchaseResult {
  const PurchaseResult.success(this.coinBalance) : error = null;
  const PurchaseResult.failure(ApiException this.error) : coinBalance = null;

  final int? coinBalance;
  final ApiException? error;

  bool get isSuccess => error == null;
}

/// How a coin pack actually gets paid for.
///
/// The wallet screen and controller talk only to this interface, never to a
/// specific gateway — swapping the mock provider for Google Play Billing
/// later is a matter of providing a different implementation, not touching
/// wallet UI/state code.
abstract class PurchaseProvider {
  /// Whether this provider should be offered at all on the current build.
  bool get isAvailable;

  Future<PurchaseResult> purchase(CoinPack pack);
}

/// Development-only top-up: creates a real gateway order, then simulates the
/// gateway's webhook callback (see `WalletApi.devConfirmOrder`). The backend
/// refuses the unsigned webhook outside `PAYMENT_PROVIDER=mock` and outside
/// non-production regardless of what this class sends, but [isAvailable]
/// still gates it client-side so a release build never surfaces the option.
class MockPurchaseProvider implements PurchaseProvider {
  const MockPurchaseProvider(this._api, this._session, {required bool isDevelopment})
    : _isDevelopment = isDevelopment;

  final WalletApi _api;
  final AuthState _session;
  final bool _isDevelopment;

  @override
  bool get isAvailable => _isDevelopment;

  @override
  Future<PurchaseResult> purchase(CoinPack pack) async {
    final userId = _session.user?.id;
    if (userId == null) {
      return const PurchaseResult.failure(
        ApiException(kind: ApiErrorKind.unauthorized, message: 'Sign in again to continue.'),
      );
    }

    try {
      final order = await _api.createOrder(pack.id);
      final balance = await _api.devConfirmOrder(
        userId: userId,
        packId: pack.id,
        orderId: order.orderId,
      );
      return PurchaseResult.success(balance);
    } on ApiException catch (e) {
      return PurchaseResult.failure(e);
    }
  }
}

/// Google Play Billing — the production purchase path.
///
/// The architecture end to end: Flutter starts a purchase with Play Billing
/// -> Play returns a purchase token on [GooglePlayBillingClient.purchaseStream]
/// -> that token and the product id go to the backend's
/// `POST /purchases/google/verify` -> the backend (never this class) asks
/// Google to confirm the purchase and only then credits the wallet -> this
/// class acknowledges the purchase with Play so it isn't auto-refunded, and
/// returns the server's own post-credit balance.
///
/// This class never credits coins itself under any code path — there is no
/// method on it that touches a balance. A purchase that fails backend
/// verification (Play says no, the token was already used, the product id
/// is unrecognised) still gets acknowledged with Play — otherwise the
/// pending purchase would block buying the same pack again — but produces
/// [PurchaseResult.failure], never a success.
///
/// NOT LIVE-VERIFIED: exercising this against a real Play Store purchase
/// needs a Play Console app listing, real product ids configured there to
/// match [CoinPack.id], and a signed release build — none of which exist in
/// this environment. The state machine below (pending/purchased/error/
/// canceled, one in-flight purchase at a time, always completing with Play)
/// is exercised in `test/unit/google_play_billing_provider_test.dart`
/// against a fake [GooglePlayBillingClient]; only the real platform channel
/// and the real Play-side verification are unverified.
class GooglePlayBillingProvider implements PurchaseProvider {
  GooglePlayBillingProvider(
    this._client,
    this._api, {
    required bool isDevelopment,
  }) : _isDevelopment = isDevelopment;

  final GooglePlayBillingClient _client;
  final PurchasesApi _api;
  final bool _isDevelopment;

  @override
  // Google Play Billing is the PRODUCTION path — offered outside development
  // builds, the exact inverse of MockPurchaseProvider's gate. The two are
  // never both available at once (see purchaseProviderProvider).
  bool get isAvailable => !_isDevelopment;

  @override
  Future<PurchaseResult> purchase(CoinPack pack) async {
    final completer = Completer<PurchaseResult>();
    late final StreamSubscription<List<BillingPurchaseUpdate>> subscription;

    // Subscribed before anything is awaited: a purchase update can in
    // principle arrive the instant buyConsumable() is called, and this must
    // never miss it by still being mid-setup.
    subscription = _client.purchaseStream.listen((updates) async {
      for (final update in updates) {
        if (update.productId != pack.id) continue;

        switch (update.status) {
          case BillingPurchaseStatus.pending:
            // Awaiting the user (e.g. confirming a payment method) — not yet
            // a result either way.
            continue;

          case BillingPurchaseStatus.canceled:
            await _client.completePurchase(update.productId);
            if (!completer.isCompleted) {
              completer.complete(
                const PurchaseResult.failure(
                  ApiException(
                    kind: ApiErrorKind.unknown,
                    message: 'Purchase cancelled.',
                  ),
                ),
              );
            }
            break;

          case BillingPurchaseStatus.error:
            await _client.completePurchase(update.productId);
            if (!completer.isCompleted) {
              completer.complete(
                PurchaseResult.failure(
                  ApiException(
                    kind: ApiErrorKind.unknown,
                    message: update.errorMessage ?? 'The purchase could not be completed.',
                  ),
                ),
              );
            }
            break;

          case BillingPurchaseStatus.purchased:
          case BillingPurchaseStatus.restored:
            final token = update.purchaseToken;
            if (token == null) {
              await _client.completePurchase(update.productId);
              if (!completer.isCompleted) {
                completer.complete(
                  const PurchaseResult.failure(
                    ApiException(
                      kind: ApiErrorKind.unknown,
                      message: 'Purchase completed without a verification token.',
                    ),
                  ),
                );
              }
              break;
            }

            try {
              // The verify call, not this update, is what decides success.
              // Play confirming a purchase locally is not the same as the
              // backend's own check against Google's servers passing.
              final verification = await _api.verifyGooglePlayPurchase(
                productId: update.productId,
                purchaseToken: token,
              );
              // Acknowledge with Play regardless of alreadyProcessed — both
              // are a genuine, settled outcome from Play's point of view.
              await _client.completePurchase(update.productId);
              if (!completer.isCompleted) {
                completer.complete(PurchaseResult.success(verification.coinBalance));
              }
            } on ApiException catch (e) {
              // Still acknowledge: an unrecoverable server-side rejection
              // (unknown product, invalid purchase) must not leave the
              // purchase stuck pending forever on the Play side.
              await _client.completePurchase(update.productId);
              if (!completer.isCompleted) completer.complete(PurchaseResult.failure(e));
            }
            break;
        }
      }
    });

    if (!await _client.isAvailable()) {
      await subscription.cancel();
      return const PurchaseResult.failure(
        ApiException(
          kind: ApiErrorKind.unknown,
          message: 'Google Play Billing is not available on this device.',
        ),
      );
    }

    try {
      await _client.buyConsumable(pack.id);
    } catch (_) {
      if (!completer.isCompleted) {
        completer.complete(
          const PurchaseResult.failure(
            ApiException(
              kind: ApiErrorKind.unknown,
              message: 'Could not start the purchase. Please try again.',
            ),
          ),
        );
      }
    }

    final result = await completer.future;
    await subscription.cancel();
    return result;
  }
}
