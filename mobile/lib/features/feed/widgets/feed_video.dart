import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/feed_video_playback.dart';
import '../../../core/theme/moco_colors.dart';
import '../../../core/theme/moco_spacing.dart';

/// One feed video, and the only place playback lifecycle is decided.
///
/// The rules, all of them driven by [isActive] rather than by any guess about
/// what is on screen:
///
/// * A controller is created ONLY while this item is active. An inactive item
///   holds no controller at all, so there is no preloading of neighbours and
///   no pool of paused players sitting on decoder resources. On a mid-range
///   Android device that ceiling matters more than shaving the swipe latency
///   this costs.
/// * Exactly one video can play, because the feed passes `isActive: true` to
///   exactly one item — the current page. Nothing here has to coordinate with
///   its siblings.
/// * Going inactive (swiped away, or the app backgrounded) disposes rather
///   than pauses, for the same reason.
/// * Audio starts muted with a visible toggle. This feed is full-screen and
///   deliberate, so sound is wanted — but a tab switch that suddenly plays
///   audio out loud, in an app whose whole purpose is paid voice calls, is the
///   wrong default. The user asks for sound.
class FeedVideo extends ConsumerStatefulWidget {
  const FeedVideo({
    super.key,
    required this.url,
    required this.isActive,
    this.onTap,
  });

  final String url;

  /// True only for the feed's current page, and only while the app is in the
  /// foreground.
  final bool isActive;

  final VoidCallback? onTap;

  @override
  ConsumerState<FeedVideo> createState() => _FeedVideoState();
}

class _FeedVideoState extends ConsumerState<FeedVideo> {
  FeedVideoPlayback? _playback;
  bool _isPreparing = false;
  bool _muted = true;
  Object? _error;

  /// Incremented on every (re)start so a slow initialize that finishes after
  /// this item went inactive cannot adopt a disposed controller or start
  /// playing over the item that replaced it.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _start();
  }

  @override
  void didUpdateWidget(FeedVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled slot pointing at different media is a different video.
    if (widget.url != oldWidget.url) {
      _stop();
      if (widget.isActive) _start();
      return;
    }
    if (widget.isActive && !oldWidget.isActive) _start();
    if (!widget.isActive && oldWidget.isActive) _stop();
  }

  Future<void> _start() async {
    if (_playback != null || _isPreparing) return;

    final generation = ++_generation;
    setState(() {
      _isPreparing = true;
      _error = null;
    });

    final playback = ref.read(feedVideoPlaybackFactoryProvider)(widget.url);
    try {
      await playback.initialize();

      // Lost the race: this item went inactive (or was rebuilt onto other
      // media) while initialize() was in flight. Throw the controller away
      // rather than let it play under the wrong item.
      if (!mounted || generation != _generation || !widget.isActive) {
        await playback.dispose();
        if (mounted && generation == _generation) {
          setState(() => _isPreparing = false);
        }
        return;
      }

      await playback.setLooping(true);
      await playback.setVolume(_muted ? 0 : 1);
      await playback.play();

      playback.addListener(_onPlaybackChanged);
      setState(() {
        _playback = playback;
        _isPreparing = false;
      });
    } catch (error) {
      await playback.dispose();
      if (!mounted || generation != _generation) return;
      setState(() {
        _isPreparing = false;
        _error = error;
      });
    }
  }

  void _stop() {
    _generation += 1;
    final playback = _playback;
    _playback = null;
    _isPreparing = false;
    if (playback != null) {
      playback.removeListener(_onPlaybackChanged);
      // Fire and forget: the widget must not wait on a platform teardown to
      // render the next page.
      playback.dispose();
    }
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    setState(() => _muted = next);
    await _playback?.setVolume(next ? 0 : 1);
  }

  @override
  void dispose() {
    // Leaving the feed must never leave a controller alive.
    _generation += 1;
    _playback?.removeListener(_onPlaybackChanged);
    _playback?.dispose();
    _playback = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback;
    final platformError = playback?.errorDescription;

    if (_error != null || platformError != null) {
      return const _VideoMessage(
        key: Key('feed_video_error'),
        icon: Icons.videocam_off_rounded,
        label: 'This video could not be played',
      );
    }

    if (playback == null || !playback.isInitialized) {
      return _VideoMessage(
        key: const Key('feed_video_loading'),
        icon: Icons.play_circle_outline_rounded,
        label: _isPreparing ? 'Loading video…' : null,
        showSpinner: _isPreparing,
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Cover the frame like a full-screen feed should, without letting a
          // portrait or landscape clip distort.
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: 1000,
              height: 1000 / (playback.aspectRatio ?? 1),
              child: playback.buildSurface(),
            ),
          ),
          Positioned(
            right: MocoSpacing.lg,
            bottom: 120,
            child: _MuteButton(muted: _muted, onPressed: _toggleMute),
          ),
        ],
      ),
    );
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onPressed});

  final bool muted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: muted ? 'Unmute video' : 'Mute video',
      child: InkWell(
        key: const Key('feed_video_mute'),
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.42),
            border: Border.all(color: MocoColors.borderSubtle),
          ),
          child: Icon(
            muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            size: 20,
            color: MocoColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Loading and error surfaces share one layout so a video that is loading and
/// a video that failed occupy the same space and the page does not jump.
class _VideoMessage extends StatelessWidget {
  const _VideoMessage({
    super.key,
    required this.icon,
    this.label,
    this.showSpinner = false,
  });

  final IconData icon;
  final String? label;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MocoColors.backgroundPrimary,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner)
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: MocoColors.accentSoft,
                ),
              )
            else
              Icon(icon, size: 44, color: MocoColors.textMuted),
            if (label != null) ...[
              const SizedBox(height: MocoSpacing.md),
              Text(
                label!,
                style: const TextStyle(
                  color: MocoColors.textMuted,
                  fontSize: 13.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
