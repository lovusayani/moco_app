import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/safety_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';

/// Report / block for one user, shared by every surface that can reach
/// another person: Listener Profile, Chat Thread, and the Feed's post menu.
/// One sheet, one implementation of the two safety actions — Discovery,
/// calls and the rest of chat enforce the resulting block server-side and
/// need no client UI of their own for it.
Future<void> showSafetyActionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required int userId,
  required String userName,
  int? callId,
  VoidCallback? onBlocked,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: MocoColors.backgroundElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(MocoRadius.xl)),
    ),
    builder: (sheetContext) => _SafetyActionsSheet(
      userId: userId,
      userName: userName,
      callId: callId,
      parentRef: ref,
      onBlocked: onBlocked,
    ),
  );
}

class _SafetyActionsSheet extends StatelessWidget {
  const _SafetyActionsSheet({
    required this.userId,
    required this.userName,
    required this.parentRef,
    this.callId,
    this.onBlocked,
  });

  final int userId;
  final String userName;
  final int? callId;
  final WidgetRef parentRef;
  final VoidCallback? onBlocked;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: MocoSpacing.sm),
              decoration: BoxDecoration(
                color: MocoColors.borderStrong,
                borderRadius: BorderRadius.circular(MocoRadius.pill),
              ),
            ),
            _Action(
              key: const Key('safety_action_report'),
              icon: Icons.flag_outlined,
              label: 'Report $userName',
              onTap: () => _report(context),
            ),
            _Action(
              key: const Key('safety_action_block'),
              icon: Icons.block_rounded,
              label: 'Block $userName',
              danger: true,
              onTap: () => _block(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _block(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    try {
      await parentRef.read(safetyApiProvider).block(userId);
      onBlocked?.call();
      messenger?.showSnackBar(
        SnackBar(content: Text('You will not see $userName again.')),
      );
    } on ApiException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(ApiErrorMapper.from(e).message)));
    }
  }

  Future<void> _report(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);

    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MocoColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(MocoRadius.xl)),
      ),
      builder: (reasonContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(MocoSpacing.lg),
                child: Text(
                  'Why are you reporting this?',
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final entry in SafetyApi.reportReasons.entries)
                _Action(
                  key: Key('report_reason_${entry.key}'),
                  icon: Icons.chevron_right_rounded,
                  label: entry.value,
                  onTap: () => Navigator.of(reasonContext).pop(entry.key),
                ),
            ],
          ),
        ),
      ),
    );

    if (navigator.canPop()) navigator.pop();
    if (reason == null) return;

    try {
      await parentRef
          .read(safetyApiProvider)
          .report(userId: userId, reason: reason, callId: callId);
      messenger?.showSnackBar(const SnackBar(content: Text('Thanks — our team will review this.')));
    } on ApiException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(ApiErrorMapper.from(e).message)));
    }
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? MocoColors.danger : MocoColors.textPrimary;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}
