import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calling/agora_call_service.dart';
import '../../core/calling/call_controller.dart';
import '../../core/calling/call_session.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_background.dart';
import 'widgets/call_action_buttons.dart';

/// The live audio call. Every coin figure on screen (balance, low-balance
/// warning) is the server's last word on the subject via [CallSession] — the
/// only thing computed locally is the elapsed-time label, which is cosmetic
/// and never fed back into any billing decision.
class ActiveAudioCallScreen extends ConsumerStatefulWidget {
  const ActiveAudioCallScreen({super.key});

  @override
  ConsumerState<ActiveAudioCallScreen> createState() =>
      _ActiveAudioCallScreenState();
}

class _ActiveAudioCallScreenState extends ConsumerState<ActiveAudioCallScreen> {
  Timer? _elapsedTimer;

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<CallSession>(callControllerProvider, (previous, next) {
      if (previous?.phase == next.phase) return;
      switch (next.phase) {
        case CallPhase.ended:
        case CallPhase.insufficientBalance:
          context.pushReplacement(Routes.callSummary);
        case CallPhase.rejected:
        case CallPhase.cancelled:
        case CallPhase.failed:
          ref.read(callControllerProvider.notifier).reset();
          if (context.canPop()) context.pop();
        default:
          break;
      }
    });

    final session = ref.watch(callControllerProvider);
    final agora = ref.watch(agoraCallServiceProvider);
    final isListener = session.role == CallRole.listener;

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
                  _StatusBar(session: session, agora: agora),
                  const Spacer(),
                  MocoAvatar(
                    key: const Key('active_call_avatar'),
                    name: session.counterpartyName ?? 'Moco',
                    imageUrl: session.counterpartyAvatarUrl,
                    size: 140,
                    ring: true,
                  ),
                  const SizedBox(height: MocoSpacing.xl),
                  Text(
                    session.counterpartyName ?? 'Moco',
                    style: const TextStyle(
                      color: MocoColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.sm),
                  Text(
                    key: const Key('active_call_timer'),
                    _elapsed(session.startedAt),
                    style: const TextStyle(
                      color: MocoColors.textSecondary,
                      fontSize: 16,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: MocoSpacing.md),
                  if (isListener)
                    Text(
                      'Earned so far · ${session.earnedThisCall} coins',
                      style: const TextStyle(
                        color: MocoColors.coinAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else if (session.balance != null)
                    Text(
                      'Balance · ${session.balance} coins'
                      '${session.ratePerMinute != null ? ' · ${session.ratePerMinute}/min' : ''}',
                      style: const TextStyle(
                        color: MocoColors.coinAccentSoft,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (!isListener && session.lowBalance)
                    Padding(
                      padding: const EdgeInsets.only(top: MocoSpacing.md),
                      child: _LowBalanceBanner(
                        minutesRemaining: session.minutesRemaining ?? 0,
                      ),
                    ),
                  ValueListenableBuilder<CallPermissionStatus?>(
                    valueListenable: agora.permissionStatus,
                    builder: (context, status, _) {
                      if (status == null || status == CallPermissionStatus.granted) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: MocoSpacing.md),
                        child: _PermissionBanner(
                          status: status,
                          onOpenSettings: agora.openAppSettings,
                        ),
                      );
                    },
                  ),
                  const Spacer(),
                  ListenableBuilder(
                    listenable: Listenable.merge([agora.muted, agora.speakerOn]),
                    builder: (context, _) {
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _ControlButton(
                            key: const Key('active_call_mute'),
                            icon: agora.muted.value
                                ? Icons.mic_off_rounded
                                : Icons.mic_rounded,
                            active: agora.muted.value,
                            label: 'Mute',
                            onPressed: agora.toggleMute,
                          ),
                          EndCallButton(
                            key: const Key('active_call_end'),
                            onPressed: session.isBusy
                                ? null
                                : () => ref
                                      .read(callControllerProvider.notifier)
                                      .endCall(),
                          ),
                          _ControlButton(
                            key: const Key('active_call_speaker'),
                            icon: agora.speakerOn.value
                                ? Icons.volume_up_rounded
                                : Icons.hearing_rounded,
                            active: agora.speakerOn.value,
                            label: 'Speaker',
                            onPressed: () => agora.setSpeaker(!agora.speakerOn.value),
                          ),
                        ],
                      );
                    },
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

  String _elapsed(DateTime? startedAt) {
    if (startedAt == null) return '00:00';
    final d = DateTime.now().difference(startedAt);
    if (d.isNegative) return '00:00';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.session, required this.agora});

  final CallSession session;
  final AgoraCallService agora;

  @override
  Widget build(BuildContext context) {
    final label = switch (session.phase) {
      CallPhase.connecting => 'Connecting…',
      CallPhase.reconnecting => 'Reconnecting…',
      CallPhase.active => session.agora?.isConfigured == false
          ? 'Media unavailable (dev mode)'
          : 'Connected',
      _ => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Text(
        label,
        style: const TextStyle(color: MocoColors.textMuted, fontSize: 12.5),
      ),
    );
  }
}

/// Non-blocking: the call keeps running underneath while Wallet is open (the
/// call controller is app-lifetime and unaffected by navigation), and only a
/// server forced-end can actually stop it — this banner never ends the call
/// itself, and tapping "Add coins" never pretends to extend it locally.
class _LowBalanceBanner extends StatelessWidget {
  const _LowBalanceBanner({required this.minutesRemaining});

  final int minutesRemaining;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('active_call_low_balance_banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: MocoColors.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: MocoColors.warning,
            size: 18,
          ),
          const SizedBox(width: MocoSpacing.sm),
          Expanded(
            child: Text(
              'Low balance — about $minutesRemaining min left.',
              style: const TextStyle(
                color: MocoColors.warning,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const Key('active_call_add_coins'),
            onPressed: () => context.push(Routes.wallet),
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

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.status, required this.onOpenSettings});

  final CallPermissionStatus status;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final message = switch (status) {
      CallPermissionStatus.microphoneDenied ||
      CallPermissionStatus.microphonePermanentlyDenied =>
        'Microphone access is needed for this call.',
      CallPermissionStatus.cameraDenied ||
      CallPermissionStatus.cameraPermanentlyDenied =>
        'Camera access is needed for video.',
      CallPermissionStatus.granted => '',
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: MocoColors.danger.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.danger.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: MocoColors.danger, fontSize: 12.5),
          ),
          if (status.isPermanentlyDenied) ...[
            const SizedBox(height: MocoSpacing.xs),
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('Open Settings'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 56,
          height: 56,
          child: Material(
            color: active
                ? MocoColors.accentPrimary.withValues(alpha: 0.18)
                : MocoColors.surfaceGlass,
            shape: CircleBorder(
              side: BorderSide(
                color: active ? MocoColors.accentPrimary : MocoColors.borderSubtle,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Icon(
                icon,
                color: active ? MocoColors.accentPrimary : MocoColors.textSecondary,
                size: 24,
              ),
            ),
          ),
        ),
        const SizedBox(height: MocoSpacing.xs),
        Text(label, style: const TextStyle(color: MocoColors.textMuted, fontSize: 12)),
      ],
    );
  }
}
