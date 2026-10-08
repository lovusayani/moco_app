import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/widgets/moco_background.dart';
import '../../../shared/models/app_config.dart';

/// Full-screen login background: the admin-configured video, else image,
/// else the app's default background — with a soft dark gradient on top so
/// the controls stay readable.
///
/// Login never waits on media: the default shows immediately; an image fades
/// in when it has loaded; a video (muted, looping, no audio ever) fades in
/// only once it is actually playing. If the video cannot load or play, the
/// image (if any) stays; if the image fails too, the default stays.
class LoginBackdrop extends StatefulWidget {
  const LoginBackdrop({super.key, this.background});

  final LoginBackground? background;

  @override
  State<LoginBackdrop> createState() => _LoginBackdropState();
}

class _LoginBackdropState extends State<LoginBackdrop> {
  VideoPlayerController? _video;
  bool _videoPlaying = false;

  @override
  void initState() {
    super.initState();
    _startVideo();
  }

  @override
  void didUpdateWidget(LoginBackdrop old) {
    super.didUpdateWidget(old);
    if (old.background?.videoUrl != widget.background?.videoUrl) {
      _disposeVideo();
      _startVideo();
    }
  }

  Future<void> _startVideo() async {
    final bg = widget.background;
    final url = bg?.isVideo == true ? bg!.videoUrl : null;
    if (url == null) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _video = controller;
    try {
      await controller.initialize();
      // Muted before play: browsers only autoplay muted video, and the
      // login background must never make a sound.
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      if (!mounted || _video != controller) return;
      setState(() => _videoPlaying = controller.value.isPlaying);
    } catch (_) {
      // Unplayable or blocked: the image/default underneath simply stays.
      if (mounted && _video == controller) {
        setState(() => _videoPlaying = false);
      }
    }
  }

  void _disposeVideo() {
    _video?.dispose();
    _video = null;
    _videoPlaying = false;
  }

  @override
  void dispose() {
    _disposeVideo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.background;
    final video = _video;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Always there: the app's default background.
        const MocoBackground(
          ambience: MocoAmbience.calm,
          child: SizedBox.expand(),
        ),
        // 2. Image (or the video's fallback/poster).
        if (bg?.imageUrl != null)
          Image.network(
            bg!.imageUrl!,
            key: const Key('login_bg_image'),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSync) => AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOut,
              child: child,
            ),
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        // 3. Video, only once it is really playing.
        if (video != null)
          AnimatedOpacity(
            key: const Key('login_bg_video'),
            opacity: _videoPlaying ? 1 : 0,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            child: _videoPlaying
                ? FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: video.value.size.width,
                      height: video.value.size.height,
                      child: VideoPlayer(video),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        // 4. Readability: soft at the top, darker where the controls sit.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x14000000), Color(0x33000000), Color(0xB3000000)],
              stops: [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}
