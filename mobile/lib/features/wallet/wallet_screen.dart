import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/app_config.dart';
import '../../shared/models/wallet.dart';
import 'wallet_controller.dart';

/// Real balance, real backend-published coin packs, and — outside production
/// only — a development top-up that exercises the full purchase path against
/// the backend's mock payment provider. Nothing here computes a coin amount;
/// every figure is what the server most recently returned.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(walletControllerProvider);
    final controller = ref.read(walletControllerProvider.notifier);
    final config = ref.watch(appConfigProvider);
    final provider = ref.watch(purchaseProviderProvider);

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: controller.load,
        color: MocoColors.accentPrimary,
        child: state.isLoading && state.balance == null
            ? const _WalletSkeleton()
            : state.error != null && state.balance == null
            ? ListView(
                children: [
                  SizedBox(
                    height: 420,
                    child: MocoErrorState(
                      key: const Key('wallet_error'),
                      message: ApiErrorMapper.from(state.error!).message,
                      onRetry: controller.load,
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  MocoSpacing.screenPadding,
                  MocoSpacing.lg,
                  MocoSpacing.screenPadding,
                  MocoSpacing.xxl,
                ),
                children: [
                  const Text(
                    'Wallet',
                    style: TextStyle(
                      color: MocoColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.lg),
                  _BalanceCard(balance: state.balance),
                  const SizedBox(height: MocoSpacing.xl),
                  MocoSectionHeader(title: 'Add coins'),
                  const SizedBox(height: MocoSpacing.md),
                  config.when(
                    loading: () => const MocoSkeleton(height: 180),
                    error: (_, __) => const Text(
                      'Could not load coin packs.',
                      style: TextStyle(color: MocoColors.textMuted),
                    ),
                    data: (cfg) => _PackGrid(
                      packs: cfg.packs,
                      purchasingPackId: state.purchasingPackId,
                      purchaseEnabled: provider.isAvailable,
                      onTap: controller.purchase,
                    ),
                  ),
                  if (!provider.isAvailable) ...[
                    const SizedBox(height: MocoSpacing.md),
                    const Text(
                      'Real purchases arrive with Google Play Billing. '
                      'Coin packs are shown at their real prices already.',
                      style: TextStyle(color: MocoColors.textMuted, fontSize: 12.5),
                    ),
                  ],
                  if (state.lastPurchaseError != null) ...[
                    const SizedBox(height: MocoSpacing.md),
                    Text(
                      ApiErrorMapper.from(state.lastPurchaseError!).message,
                      style: const TextStyle(color: MocoColors.danger, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: MocoSpacing.xl),
                  MocoSectionHeader(title: 'Recent activity'),
                  const SizedBox(height: MocoSpacing.md),
                  _LedgerSection(),
                ],
              ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});

  final WalletBalance? balance;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      strong: true,
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Coin balance',
            style: TextStyle(color: MocoColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: MocoSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ShaderMask(
                shaderCallback: (rect) => MocoColors.coinGradient.createShader(rect),
                child: Text(
                  '${balance?.coinBalance ?? 0}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 6, bottom: 6),
                child: Text(
                  'coins',
                  style: TextStyle(color: MocoColors.textMuted, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: MocoSpacing.md),
          Row(
            children: [
              Expanded(
                child: _MinutesChip(
                  icon: Icons.call_rounded,
                  label: 'Audio',
                  minutes: balance?.audioMinutes,
                ),
              ),
              const SizedBox(width: MocoSpacing.md),
              Expanded(
                child: _MinutesChip(
                  icon: Icons.videocam_rounded,
                  label: 'Video',
                  minutes: balance?.videoMinutes,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MinutesChip extends StatelessWidget {
  const _MinutesChip({required this.icon, required this.label, required this.minutes});

  final IconData icon;
  final String label;
  final int? minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.md, vertical: MocoSpacing.sm),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.sm),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: MocoColors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${minutes ?? 0} min $label',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: MocoColors.textSecondary, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _PackGrid extends StatelessWidget {
  const _PackGrid({
    required this.packs,
    required this.purchasingPackId,
    required this.purchaseEnabled,
    required this.onTap,
  });

  final List<CoinPack> packs;
  final String? purchasingPackId;
  final bool purchaseEnabled;
  final ValueChanged<CoinPack> onTap;

  @override
  Widget build(BuildContext context) {
    if (packs.isEmpty) {
      return const Text(
        'No coin packs available right now.',
        style: TextStyle(color: MocoColors.textMuted),
      );
    }

    // "Best value" isn't a server flag — `constants.js` publishes price/coins/
    // bonus only — so this is derived purely from that existing data (highest
    // coins-per-rupee among packs with more than one option), never a new
    // client-invented field.
    String? bestValueId;
    if (packs.length > 1) {
      var bestRatio = -1.0;
      for (final pack in packs) {
        final ratio = pack.totalCoins / pack.priceInr;
        if (ratio > bestRatio) {
          bestRatio = ratio;
          bestValueId = pack.id;
        }
      }
    }

    return Column(
      children: [
        for (final pack in packs) ...[
          _PackRow(
            pack: pack,
            isBestValue: pack.id == bestValueId,
            busy: purchasingPackId == pack.id,
            enabled: purchaseEnabled && purchasingPackId == null,
            purchaseEnabled: purchaseEnabled,
            onTap: () => onTap(pack),
          ),
          if (pack != packs.last) const SizedBox(height: MocoSpacing.sm),
        ],
      ],
    );
  }
}

class _PackRow extends StatelessWidget {
  const _PackRow({
    required this.pack,
    required this.isBestValue,
    required this.busy,
    required this.enabled,
    required this.purchaseEnabled,
    required this.onTap,
  });

  final CoinPack pack;
  final bool isBestValue;
  final bool busy;
  final bool enabled;
  final bool purchaseEnabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      key: Key('coin_pack_${pack.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.md,
      ),
      strong: isBestValue,
      glow: isBestValue,
      onTap: enabled ? onTap : null,
      child: Row(
        children: [
          const Icon(
            Icons.monetization_on_rounded,
            color: MocoColors.coinAccent,
            size: 26,
          ),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${pack.totalCoins} coins',
                      style: const TextStyle(
                        color: MocoColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isBestValue) ...[
                      const SizedBox(width: 6),
                      const _BestValueBadge(),
                    ],
                  ],
                ),
                if (pack.bonus > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${pack.coins} + ${pack.bonus} bonus',
                      style: const TextStyle(
                        color: MocoColors.coinAccentSoft,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: MocoSpacing.md),
          Text(
            '₹${pack.priceInr}',
            style: const TextStyle(
              color: MocoColors.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: MocoSpacing.sm),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (purchaseEnabled)
            const Icon(Icons.add_circle_rounded, color: MocoColors.accentPrimary, size: 22),
        ],
      ),
    );
  }
}

class _BestValueBadge extends StatelessWidget {
  const _BestValueBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        gradient: MocoColors.coinGradient,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
      ),
      child: const Text(
        'Best value',
        style: TextStyle(
          color: Color(0xFF2A1338),
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _LedgerSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walletApi = ref.watch(walletApiProvider);
    final ledger = ref.watch(_recentLedgerProvider(walletApi));

    return ledger.when(
      loading: () => const MocoSkeleton(height: 120),
      error: (_, __) => const Text(
        'Could not load recent activity.',
        style: TextStyle(color: MocoColors.textMuted),
      ),
      data: (page) {
        if (page.entries.isEmpty) {
          return const Text(
            'No activity yet.',
            style: TextStyle(color: MocoColors.textMuted),
          );
        }
        return MocoGlassCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final entry in page.entries) ...[
                _LedgerRow(entry: entry),
                if (entry != page.entries.last)
                  const Divider(height: 1, color: MocoColors.borderSubtle),
              ],
            ],
          ),
        );
      },
    );
  }
}

final _recentLedgerProvider = FutureProvider.autoDispose
    .family<LedgerPage, dynamic>((ref, walletApi) => walletApi.ledger(limit: 10));

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = entry.isCredit ? MocoColors.online : MocoColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            entry.isCredit ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: MocoSpacing.sm),
          Expanded(
            child: Text(
              entry.label,
              style: const TextStyle(color: MocoColors.textPrimary, fontSize: 13.5),
            ),
          ),
          Text(
            '${entry.isCredit ? '+' : ''}${entry.delta}',
            style: TextStyle(color: color, fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _WalletSkeleton extends StatelessWidget {
  const _WalletSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(MocoSpacing.screenPadding),
      children: const [
        MocoSkeleton(width: 100, height: 24),
        SizedBox(height: MocoSpacing.lg),
        MocoSkeleton(height: 140, radius: MocoRadius.lg),
        SizedBox(height: MocoSpacing.xl),
        MocoSkeleton(width: 120, height: 18),
        SizedBox(height: MocoSpacing.md),
        MocoSkeleton(height: 180, radius: MocoRadius.lg),
      ],
    );
  }
}
