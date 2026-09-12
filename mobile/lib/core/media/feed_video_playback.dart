import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

/// Playback for one feed video.
///
/// `video_player` is imported in this file and nowhere else. That is not
/// ceremony: every platform call it makes is unavailable in a widget test, so
/// without this seam the lifecycle rules that actually matter — one video
/// playing at a time, paused off-screen, paused in the background, disposed on
/// the way out — could only be verified on a device. Behind it, they are
/// ordinary tests.
abstract class FeedVideoPlayback implements Listenable {
  /// Loads enough of the media to know its size and show a first frame.
  Future<void> initialize();

  Future<void> play();
  Future<void> pause();
  Future<void> setLooping(bool value);
  Future<void> setVolume(double value);
  Future<void> dispose();

  bool get isInitialized;
  bool get isPlaying;

  /// Null until initialized, and null for media whose size never resolves.
  double? get aspectRatio;

  /// The error the platform reported, or null. Surfaced rather than swallowed:
  /// a video that cannot play must say so, not sit on a black rectangle.
  String? get errorDescription;

  /// The render surface. Only valid once [isInitialized].
  Widget buildSurface();
}

/// Creates playback for a media URL. Injected so tests can substitute a fake.
typedef FeedVideoPlaybackFactory = FeedVideoPlayback Function(String url);

/// The real implementation, wrapping one [VideoPlayerController].
class _VideoPlayerPlayback implements FeedVideoPlayback {
  _VideoPlayerPlayback(String url)
    : _controller = VideoPlayerController.networkUrl(Uri.parse(url));

  final VideoPlayerController _controller;

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> setLooping(bool value) => _controller.setLooping(value);

  @override
  Future<void> setVolume(double value) => _controller.setVolume(value);

  @override
  Future<void> dispose() => _controller.dispose();

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  bool get isPlaying => _controller.value.isPlaying;

  @override
  double? get aspectRatio =>
      _controller.value.isInitialized ? _controller.value.aspectRatio : null;

  @override
  String? get errorDescription => _controller.value.errorDescription;

  @override
  Widget buildSurface() => VideoPlayer(_controller);

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);
}

final feedVideoPlaybackFactoryProvider = Provider<FeedVideoPlaybackFactory>(
  (ref) => (url) => _VideoPlayerPlayback(url),
);
