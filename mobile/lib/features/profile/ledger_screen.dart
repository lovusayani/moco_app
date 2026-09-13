import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../core/widgets/moco_states.dart';
import 'ledger_controller.dart';

/// One paginated ledger screen for both the coin ledger and the listener
/// earnings ledger — same list shape (append-only, newest first, cursor
/// pagination), differing only in which provider feeds it.
class LedgerScreen extends ConsumerWidget {
  const LedgerScreen({
    super.key,
    required this.title,
    required this.provider,
    required this.currencyPrefix,
  });

  final String title;
  final AutoDisposeStateNotifierProvider<LedgerController, LedgerState> provider;

  /// '' for coins (rendered as a plain integer), '₹' for earnings/payout rupees.
  final String currencyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text(title)),
      body: _Body(state: state, controller: controller, currencyPrefix: currencyPrefix),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.controller, required this.currencyPrefix});

  final LedgerState state;
  final LedgerController controller;
  final String currencyPrefix;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading && state.rows.isEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.all(MocoSpacing.screenPadding),
        itemCount: 6,
        itemBuilder: (context, index) => const Padding(
          padding: EdgeInsets.only(bottom: MocoSpacing.md),
          child: MocoSkeleton(height: 56),
        ),
      );
    }

    if (state.isFatalError) {
      return MocoErrorState(
        key: const Key('ledger_error'),
        message: ApiErrorMapper.from(state.error!).message,
        onRetry: controller.load,
      );
    }

    if (state.isEmpty) {
      return const MocoEmptyState(
        key: Key('ledger_empty'),
        title: 'No activity yet',
        message: 'Transactions will show up here once there are any.',
        icon: Icons.receipt_long_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: controller.load,
      color: MocoColors.accentPrimary,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels > notification.metrics.maxScrollExtent - 200) {
            controller.loadMore();
          }
          return false;
        },
        child: ListView.separated(
          key: const Key('ledger_list'),
          padding: const EdgeInsets.symmetric(
            horizontal: MocoSpacing.screenPadding,
            vertical: MocoSpacing.md,
          ),
          itemCount: state.rows.length + (state.hasMore ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: MocoSpacing.sm),
          itemBuilder: (context, index) {
            if (index >= state.rows.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: MocoSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            return _LedgerRow(row: state.rows[index], currencyPrefix: currencyPrefix);
          },
        ),
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.row, required this.currencyPrefix});

  final LedgerRow row;
  final String currencyPrefix;

  @override
  Widget build(BuildContext context) {
    final sign = row.isCredit ? '+' : '-';
    final color = row.isCredit ? MocoColors.success : MocoColors.textPrimary;

    return Container(
      padding: const EdgeInsets.all(MocoSpacing.md),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatRelativeTime(row.createdAt),
                  style: const TextStyle(color: MocoColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            '$sign$currencyPrefix${row.delta.abs()}',
            style: TextStyle(color: color, fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
