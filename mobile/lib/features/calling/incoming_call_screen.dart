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
import '../safety/safety_actions_sheet.dart';
import 'widgets/call_action_buttons.dart';

/// Shown to a listener the instant `call:incoming` arrives, from wherever they
/// are in the app (see [CallController] — the subscription is global, not
/// screen-scoped). Accept/decline are both guarded against a double tap by
/// [CallSession.isBusy].
class IncomingCallScreen extends ConsumerWidget {
  const IncomingCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<CallSession>(callControllerProvider, (previous, next) {
      if (previous?.phase == next.phase) return;

      switch (next.phase) {
        case CallPhase.connecting:
        case CallPhase.active:
          final route = next.callType == CallType.video
              ? Routes.callActiveVideo
              : Routes.callActiveAudio;
          context.pushReplacement(route);
        case CallPhase.rejected:
          ref.read(callControllerProvider.notifier).reset();
          if (context.canPop()) context.pop();
        case CallPhase.ended:
          // The caller cancelled while this screen was up, or the call was
          // settled some other way before it was ever accepted here.
          if (next.summary != null && (next.summary!.billedMinutes > 0)) {
            context.pushReplacement(Routes.callSummary);
          } else {
            ref.read(callControllerProvider.notifier).reset();
            if (context.canPop()) context.pop();
          }
        default:
          break;
      }
    });

    final session = ref.watch(callControllerProvider);

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: MocoBackground(
          ambience: MocoAmbience.rich,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(MocoSpacing.screenPadding),
              child: Column(
                children: [
                  const SizedBox(height: MocoSpacing.xl),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        session.callType == CallType.video
                            ? 'Incoming video call'
                            : 'Incoming audio call',
                        style: const TextStyle(
                          color: MocoColors.textMuted,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (session.counterpartyId != null) ...[
                        const SizedBox(width: MocoSpacing.sm),
                        MocoIconButton(
                          key: const Key('incoming_call_report'),
                          icon: Icons.shield_outlined,
                          tooltip: 'Report or block',
                          onPressed: () => showSafetyActionsSheet(
                            context: context,
                            ref: ref,
                            userId: session.counterpartyId!,
                            userName: session.counterpartyName ?? 'this user',
                          ),
                        ),
                      ],
                    ],
                  ),
                  const Spacer(),
                  MocoAvatar(
                    key: const Key('incoming_call_avatar'),
                    name: session.counterpartyName ?? 'Moco',
                    imageUrl: session.counterpartyAvatarUrl,
                    size: 140,
                    ring: true,
                  ),
                  const SizedBox(height: MocoSpacing.xl),
                  Text(
                    session.counterpartyName ?? 'Someone is calling',
                    style: const TextStyle(
                      color: MocoColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.sm),
                  Icon(
                    session.callType == CallType.video
                        ? Icons.videocam_rounded
                        : Icons.call_rounded,
                    color: MocoColors.accentSoft,
                    size: 22,
                  ),
                  if (session.ratePerMinute != null ||
                      session.freeSecondsGranted > 0) ...[
                    const SizedBox(height: MocoSpacing.lg),
                    _EarningsCard(session: session),
                  ],
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Column(
                        children: [
                          CallCircleButton(
                            key: const Key('incoming_call_decline'),
                            icon: Icons.call_end_rounded,
                            color: MocoColors.danger,
                            onPressed: session.isBusy
                                ? null
                                : () => ref
                                      .read(callControllerProvider.notifier)
                                      .declineCall(),
                          ),
                          const SizedBox(height: MocoSpacing.sm),
                          const Text(
                            'Decline',
                            style: TextStyle(
                              color: MocoColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          CallCircleButton(
                            key: const Key('incoming_call_accept'),
                            icon: Icons.call_rounded,
                            color: MocoColors.online,
                            onPressed: session.isBusy
                                ? null
                                : () => ref
                                      .read(callControllerProvider.notifier)
                                      .acceptCall(),
                          ),
                          const SizedBox(height: MocoSpacing.sm),
                          const Text(
                            'Accept',
                            style: TextStyle(
                              color: MocoColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: MocoSpacing.xxl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass rate/earnings summary — both figures are server data already on
/// [CallSession] (`ratePerMinute`, `freeSecondsGranted`), never a client
/// projection.
class _EarningsCard extends StatelessWidget {
  const _EarningsCard({required this.session});

  final CallSession session;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.md,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session.ratePerMinute != null) ...[
            const Icon(Icons.monetization_on_rounded, color: MocoColors.coinAccent, size: 18),
            const SizedBox(width: 6),
            Text(
              '${session.ratePerMinute}/min',
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (session.ratePerMinute != null && session.freeSecondsGranted > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: MocoSpacing.sm),
              child: Text('·', style: TextStyle(color: MocoColors.textMuted)),
            ),
          if (session.freeSecondsGranted > 0)
            const Text(
              'First-time caller',
              style: TextStyle(
                color: MocoColors.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}
