import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calling/call_controller.dart';
import '../../core/calling/call_session.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/call.dart';

/// The end of every call funnels here — normal hangup, decline, forced end for
/// insufficient balance. Every figure on this screen is copied straight from
/// [CallSession.summary], which is exactly what the server returned; nothing
/// here recomputes a duration or a coin total.
class CallEndedSummaryScreen extends ConsumerWidget {
  const CallEndedSummaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(callControllerProvider);
    final summary = session.summary;
    final isListener = session.role == CallRole.listener;
    final insufficientBalance = session.phase == CallPhase.insufficientBalance ||
        summary?.endReason == CallEndReason.insufficientBalance;

    return Scaffold(
      body: MocoBackground(
        ambience: MocoAmbience.standard,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(MocoSpacing.screenPadding),
            child: Column(
              children: [
                const Spacer(),
                MocoAvatar(
                  name: session.counterpartyName ?? 'Moco',
                  imageUrl: session.counterpartyAvatarUrl,
                  size: 96,
                ),
                const SizedBox(height: MocoSpacing.lg),
                Text(
                  session.counterpartyName ?? 'Call ended',
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: MocoSpacing.xs),
                Text(
                  _reasonLabel(session.phase, summary?.endReason),
                  style: const TextStyle(
                    color: MocoColors.textMuted,
                    fontSize: 14,
                  ),
                ),
                if (insufficientBalance) ...[
                  const SizedBox(height: MocoSpacing.lg),
                  _InsufficientBalanceBanner(
                    onAddCoins: () => context.push(Routes.wallet),
                  ),
                ],
                const SizedBox(height: MocoSpacing.xxl),
                if (summary != null)
                  MocoGlassCard(
                    child: Column(
                      children: [
                        _SummaryRow(
                          label: 'Call type',
                          value: session.callType == CallType.video
                              ? 'Video'
                              : 'Audio',
                          icon: session.callType == CallType.video
                              ? Icons.videocam_rounded
                              : Icons.call_rounded,
                        ),
                        const _RowDivider(),
                        _SummaryRow(
                          label: 'Duration',
                          value: _formatDuration(summary.durationSeconds),
                          icon: Icons.timer_outlined,
                        ),
                        const _RowDivider(),
                        _SummaryRow(
                          label: 'Billed minutes',
                          value: '${summary.billedMinutes}',
                          icon: Icons.receipt_long_rounded,
                        ),
                        const _RowDivider(),
                        if (isListener)
                          _SummaryRow(
                            label: 'You earned',
                            value: '${summary.listenerEarned ?? 0} coins',
                            icon: Icons.savings_rounded,
                            valueColor: MocoColors.coinAccent,
                          )
                        else ...[
                          _SummaryRow(
                            label: 'Coins spent',
                            value: '${summary.coinsSpent}',
                            icon: Icons.monetization_on_outlined,
                            valueColor: MocoColors.coinAccent,
                          ),
                          if (summary.callerBalance != null) ...[
                            const _RowDivider(),
                            _SummaryRow(
                              label: 'Remaining balance',
                              value: '${summary.callerBalance} coins',
                              icon: Icons.account_balance_wallet_outlined,
                              valueColor: MocoColors.coinAccent,
                            ),
                          ],
                        ],
                      ],
                    ),
                  )
                else
                  // A rejected/cancelled call before any billing has no
                  // settlement summary — nothing was spent or earned.
                  Text(
                    'No coins were charged for this call.',
                    style: const TextStyle(
                      color: MocoColors.textMuted,
                      fontSize: 14,
                    ),
                  ),
                const Spacer(),
                MocoPrimaryButton(
                  key: const Key('call_summary_done'),
                  label: 'Done',
                  onPressed: () {
                    ref.read(callControllerProvider.notifier).reset();
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go(Routes.discovery);
                    }
                  },
                ),
                const SizedBox(height: MocoSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _reasonLabel(CallPhase phase, CallEndReason? reason) {
    if (phase == CallPhase.insufficientBalance ||
        reason == CallEndReason.insufficientBalance) {
      return 'Call ended — balance ran out';
    }
    return switch (reason) {
      CallEndReason.rejected => 'Call declined',
      CallEndReason.callerHangup => 'Call ended',
      CallEndReason.listenerHangup => 'Call ended',
      CallEndReason.disconnect => 'Call disconnected',
      CallEndReason.timeout => 'No answer',
      _ => 'Call ended',
    };
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }
}

/// Shown only when this call actually ended for insufficient balance — driven
/// by the server's own end reason, never guessed from the coin figures below.
class _InsufficientBalanceBanner extends StatelessWidget {
  const _InsufficientBalanceBanner({required this.onAddCoins});

  final VoidCallback onAddCoins;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('call_summary_insufficient_balance_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.md,
      ),
      decoration: BoxDecoration(
        color: MocoColors.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: MocoColors.warning, size: 20),
          const SizedBox(width: MocoSpacing.sm),
          const Expanded(
            child: Text(
              'Your balance ran out mid-call.',
              style: TextStyle(
                color: MocoColors.warning,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const Key('call_summary_add_coins'),
            onPressed: onAddCoins,
            style: TextButton.styleFrom(
              foregroundColor: MocoColors.warning,
              padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.sm),
              minimumSize: const Size(0, 32),
            ),
            child: const Text(
              'Add coins',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: MocoColors.textMuted),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: MocoColors.textSecondary, fontSize: 14),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? MocoColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, color: MocoColors.borderSubtle);
  }
}
