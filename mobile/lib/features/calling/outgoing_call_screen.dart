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
import '../../shared/models/call.dart';
import 'widgets/call_action_buttons.dart';

/// The caller's screen from the moment they tap Audio/Video until the
/// listener answers. Purely a reflection of [CallSession] — this screen makes
/// no billing or availability decision of its own.
class OutgoingCallScreen extends ConsumerStatefulWidget {
  const OutgoingCallScreen({super.key});

  @override
  ConsumerState<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends ConsumerState<OutgoingCallScreen> {
  @override
  Widget build(BuildContext context) {
    ref.listen<CallSession>(callControllerProvider, (previous, next) {
      if (previous?.phase == next.phase) return;

      switch (next.phase) {
        case CallPhase.connecting:
        case CallPhase.active:
          final route = next.callType == CallType.video
              ? Routes.callActiveVideo
              : Routes.callActiveAudio;
          context.pushReplacement(route);
        case CallPhase.ended:
        case CallPhase.insufficientBalance:
          context.pushReplacement(Routes.callSummary);
        case CallPhase.cancelled:
        case CallPhase.rejected:
        case CallPhase.failed:
          // Nothing was ever billed for a call that never connected — pop back
          // rather than show an empty summary.
          ref.read(callControllerProvider.notifier).reset();
          if (context.canPop()) context.pop();
        default:
          break;
      }
    });

    final session = ref.watch(callControllerProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(callControllerProvider.notifier).cancelOutgoing();
      },
      child: Scaffold(
        body: MocoBackground(
          ambience: MocoAmbience.rich,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(MocoSpacing.screenPadding),
              child: Column(
                children: [
                  const SizedBox(height: MocoSpacing.xxl),
                  if (session.freeSecondsGranted > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MocoSpacing.lg,
                        vertical: MocoSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: MocoColors.coinAccent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(MocoRadius.pill),
                        border: Border.all(
                          color: MocoColors.coinAccent.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        'First call · ${session.freeSecondsGranted}s free',
                        style: const TextStyle(
                          color: MocoColors.coinAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  const Spacer(),
                  MocoAvatar(
                    key: const Key('outgoing_call_avatar'),
                    name: session.counterpartyName ?? 'Moco',
                    imageUrl: session.counterpartyAvatarUrl,
                    size: 140,
                    ring: true,
                  ),
                  const SizedBox(height: MocoSpacing.xl),
                  Text(
                    session.counterpartyName ?? 'Calling…',
                    style: const TextStyle(
                      color: MocoColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.sm),
                  Text(
                    key: const Key('outgoing_call_status'),
                    _statusLabel(session.phase),
                    style: const TextStyle(
                      color: MocoColors.textMuted,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.sm),
                  if (session.ratePerMinute != null)
                    Text(
                      '${session.callType == CallType.video ? 'Video' : 'Audio'} '
                      '· ${session.ratePerMinute}/min',
                      style: const TextStyle(
                        color: MocoColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  const Spacer(),
                  Center(
                    child: EndCallButton(
                      key: const Key('outgoing_call_cancel'),
                      onPressed: session.isBusy
                          ? null
                          : () => ref
                                .read(callControllerProvider.notifier)
                                .cancelOutgoing(),
                    ),
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

  String _statusLabel(CallPhase phase) => switch (phase) {
    CallPhase.initiating => 'Calling…',
    CallPhase.ringing => 'Ringing…',
    CallPhase.connecting => 'Connecting…',
    _ => 'Calling…',
  };
}
