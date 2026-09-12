import 'dart:async';

import 'package:flutter/material.dart';
import 'package:moco/core/media/feed_video_playback.dart';

/// A [FeedVideoPlayback] that records what was asked of it.
///
/// The lifecycle rules worth testing — one video playing, paused off-screen,
/// paused in the background, disposed on the way out — are about the sequence
/// of calls made to the player, not about decoding video. This records that
/// sequence so those rules can be asserted without a platform channel.
class FakeVideoPlayback extends ChangeNotifier implements FeedVideoPlayback {
  FakeVideoPlayback(this.url);

  final String url;

  int initializeCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;
  bool looping = false;
  double volume = 1;

  /// Makes initialize() hang until [completeInitialize] is called, so the
  /// "went inactive mid-initialize" race can be reproduced deliberately.
  bool blockInitialize = false;
  final _initializeGate = <Completer<void>>[];

  /// Makes initialize() throw, for the playback-error state.
  Object? initializeError;

  bool _initialized = false;
  bool _playing = false;

  void completeInitialize() {
    for (final gate in [..._initializeGate]) {
      if (!gate.isCompleted) gate.complete();
    }
    _initializeGate.clear();
  }

  @override
  Future<void> initialize() async {
    initializeCount += 1;
    if (blockInitialize) await _waitForGate();
    if (initializeError != null) throw initializeError!;
    _initialized = true;
  }

  Future<void> _waitForGate() {
    final gate = Completer<void>();
    _initializeGate.add(gate);
    return gate.future;
  }

  @override
  Future<void> play() async {
    playCount += 1;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauseCount += 1;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> setLooping(bool value) async => looping = value;

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    _playing = false;
    super.dispose();
  }

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isPlaying => _playing;

  @override
  double? get aspectRatio => _initialized ? 9 / 16 : null;

  @override
  String? get errorDescription => null;

  @override
  Widget buildSurface() =>
      ColoredBox(key: const Key('fake_video_surface'), color: Colors.black);
}

/// Hands out fakes and keeps every one created, so a test can assert that a
/// controller was disposed rather than merely dropped.
class RecordingPlaybackFactory {
  final List<FakeVideoPlayback> created = [];

  /// Applied to each new fake before it is returned.
  void Function(FakeVideoPlayback)? configure;

  FeedVideoPlayback call(String url) {
    final playback = FakeVideoPlayback(url);
    configure?.call(playback);
    created.add(playback);
    return playback;
  }

  FakeVideoPlayback get last => created.last;
  int get count => created.length;
}
