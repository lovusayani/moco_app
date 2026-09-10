import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/calling/call_controller.dart';
import '../../core/calling/call_session.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_avatar.dart';
import 'widgets/call_action_buttons.dart';

/// The live video call. Remote video fills the screen; the local preview sits
/// in a small corner tile, matching the approved design. Never renders a fake
/// remote frame — with no remote UID yet, the space shows the counterparty's
/// avatar instead of a blank/frozen surface.
class ActiveVideoCallScreen extends ConsumerStatefulWidget {
  const ActiveVideoCallScreen({super.key});

  @override
  ConsumerState<ActiveVideoCallScreen> createState() =>
      _ActiveVideoCallScreenState();
}

class _ActiveVideoCallScreenState extends ConsumerState<ActiveVideoCallScreen> {
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

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: MocoColors.backgroundPrimary,
        body: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: agora.remoteJoined,
                builder: (context, joined, _) {
                  final engine = agora.engineOrNull;
                  if (!joined || engine == null) {
                    return _AvatarFallback(session: session);
                  }
                  return ValueListenableBuilder<int?>(
                    valueListenable: agora.remoteUid,
                    builder: (context, uid, _) {
                      if (uid == null) return _AvatarFallback(session: session);
                      return AgoraVideoView(
                        controller: VideoViewController.remote(
                          rtcEngine: engine,
                          canvas: VideoCanvas(uid: uid),
                          connection: RtcConnection(channelId: session.agora?.channel),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(MocoSpacing.screenPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.counterpartyName ?? 'Moco',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                            ),
                          ),
                        ),
                        Text(
                          key: const Key('active_video_timer'),
                          _elapsed(session.startedAt),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: MocoSpacing.sm),
                    if (session.balance != null && session.role == CallRole.caller)
                      Text(
                        'Balance · ${session.balance} coins',
                        style: const TextStyle(
                          color: MocoColors.coinAccentSoft,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                        ),
                      ),
                    const Spacer(),
                    // Local preview tile — only ever a real Agora surface or
                    // nothing; never a stand-in frame pretending to be video.
                    ValueListenableBuilder<bool>(
                      valueListenable: agora.localVideoEnabled,
                      builder: (context, enabled, _) {
                        final engine = agora.engineOrNull;
                        if (!enabled || engine == null) return const SizedBox.shrink();
                        return Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            width: 96,
                            height: 130,
                            margin: const EdgeInsets.only(bottom: MocoSpacing.lg),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(MocoRadius.md),
                              border: Border.all(color: MocoColors.borderStrong),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: AgoraVideoView(
                              controller: VideoViewController(
                                rtcEngine: engine,
                                canvas: const VideoCanvas(uid: 0),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    ListenableBuilder(
                      listenable: Listenable.merge([
                        agora.muted,
                        agora.localVideoEnabled,
                      ]),
                      builder: (context, _) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _VideoControlButton(
                              key: const Key('active_video_mute'),
                              icon: agora.muted.value
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_rounded,
                              active: agora.muted.value,
                              onPressed: agora.toggleMute,
                            ),
                            EndCallButton(
                              key: const Key('active_video_end'),
                              onPressed: session.isBusy
                                  ? null
                                  : () => ref
                                        .read(callControllerProvider.notifier)
                                        .endCall(),
                            ),
                            _VideoControlButton(
                              key: const Key('active_video_camera_toggle'),
                              icon: agora.localVideoEnabled.value
                                  ? Icons.videocam_rounded
                                  : Icons.videocam_off_rounded,
                              active: !agora.localVideoEnabled.value,
                              onPressed: agora.toggleLocalVideo,
                            ),
                            _VideoControlButton(
                              key: const Key('active_video_switch_camera'),
                              icon: Icons.cameraswitch_rounded,
                              onPressed: agora.switchCamera,
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: MocoSpacing.lg),
                  ],
                ),
              ),
            ),
          ],
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
    return '$m:$s';
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.session});

  final CallSession session;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: MocoColors.backgroundElevated),
      child: Center(
        child: MocoAvatar(
          name: session.counterpartyName ?? 'Moco',
          imageUrl: session.counterpartyAvatarUrl,
          size: 120,
        ),
      ),
    );
  }
}

class _VideoControlButton extends StatelessWidget {
  const _VideoControlButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: Material(
        color: active
            ? MocoColors.accentPrimary.withValues(alpha: 0.28)
            : Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
