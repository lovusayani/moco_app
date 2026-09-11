// prefer_initializing_formals: `required this._isDevelopment` is invalid for a
// named parameter (private names can't be named parameters).
// ignore_for_file: prefer_initializing_formals

import '../api/wallet_api.dart';
import '../auth/auth_state.dart';
import '../errors/api_exception.dart';
import '../../shared/models/app_config.dart';

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
/// Not implemented: it needs a Play Console app listing, real product ids
/// configured there, and the `in_app_purchase` plugin wired to launch the
/// native purchase flow. The shape it must fill in is fixed by this
/// interface and by the backend: purchase in Flutter -> obtain a Play
/// purchase token -> send the token to the backend for verification -> the
/// backend (not this client) credits the wallet only once Play confirms the
/// purchase is genuine. See docs/API.md's wallet section for why crediting
/// never happens from a client claim.
// class GooglePlayBillingProvider implements PurchaseProvider { ... }
