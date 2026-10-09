import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/media/feed_video_playback.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/storage/secure_store.dart';
import 'package:moco/features/feed/widgets/feed_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_video_playback.dart';

/// The video lifecycle rules, asserted on the widget that owns them.
void main() {
  late RecordingPlaybackFactory factory;
  late AppPreferences prefs;

  Future<void> usePrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    prefs = await AppPreferences.create();
  }

  setUp(() async {
    factory = RecordingPlaybackFactory();
    await usePrefs({});
  });

  Widget subject({
    required bool isActive,
    String url = 'https://v/a.mp4',
    bool loop = true,
    VoidCallback? onCompleted,
  }) {
    return ProviderScope(
      overrides: [
        appPreferencesProvider.overrideWithValue(prefs),
        feedVideoPlaybackFactoryProvider.overrideWithValue(factory.call),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: FeedVideo(
            url: url,
            isActive: isActive,
            loop: loop,
            onCompleted: onCompleted,
          ),
        ),
      ),
    );
  }

  testWidgets('an inactive video creates no controller at all', (tester) async {
    await tester.pumpWidget(subject(isActive: false));
    await tester.pumpAndSettle();

    // Not merely paused — nothing is allocated. This is what keeps a long
    // feed from holding a pool of decoders open.
    expect(factory.count, 0);
    expect(find.byKey(const Key('feed_video_loading')), findsOneWidget);
  });

  testWidgets('an active video initializes, loops, and plays muted', (tester) async {
    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();

    expect(factory.count, 1);
    expect(factory.last.initializeCount, 1);
    expect(factory.last.playCount, 1);
    expect(factory.last.looping, isTrue);
    // Muted by default: a tab switch must not suddenly play audio out loud.
    expect(factory.last.volume, 0);
    expect(find.byKey(const Key('fake_video_surface')), findsOneWidget);
  });

  testWidgets('the mute control turns sound on and off', (tester) async {
    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feed_video_mute')));
    await tester.pumpAndSettle();
    expect(factory.last.volume, 1);

    await tester.tap(find.byKey(const Key('feed_video_mute')));
    await tester.pumpAndSettle();
    expect(factory.last.volume, 0);
  });

  testWidgets('going inactive disposes the controller', (tester) async {
    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();
    expect(factory.last.disposeCount, 0);

    await tester.pumpWidget(subject(isActive: false));
    await tester.pumpAndSettle();

    expect(factory.last.disposeCount, 1);
    expect(find.byKey(const Key('fake_video_surface')), findsNothing);
  });

  testWidgets('becoming active again starts a fresh controller', (tester) async {
    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(subject(isActive: false));
    await tester.pumpAndSettle();

    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();

    expect(factory.count, 2, reason: 'a disposed controller is never reused');
    expect(factory.last.playCount, 1);
  });

  testWidgets('leaving the feed disposes the controller', (tester) async {
    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();

    // Replace the whole tree, as navigating away does.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(factory.last.disposeCount, 1, reason: 'no controller may outlive the widget');
  });

  testWidgets('pointing at different media replaces the controller', (tester) async {
    await tester.pumpWidget(subject(isActive: true, url: 'https://v/a.mp4'));
    await tester.pumpAndSettle();
    final first = factory.last;

    await tester.pumpWidget(subject(isActive: true, url: 'https://v/b.mp4'));
    await tester.pumpAndSettle();

    expect(first.disposeCount, 1);
    expect(factory.count, 2);
    expect(factory.last.url, 'https://v/b.mp4');
  });

  testWidgets('a video that goes inactive mid-initialize never plays', (tester) async {
    factory.configure = (playback) => playback.blockInitialize = true;

    await tester.pumpWidget(subject(isActive: true));
    await tester.pump();
    expect(factory.count, 1);
    expect(factory.last.playCount, 0, reason: 'still initializing');

    // Swiped away before initialize() returned.
    await tester.pumpWidget(subject(isActive: false));
    await tester.pump();

    factory.created.first.completeInitialize();
    await tester.pumpAndSettle();

    // The late initialize must not resurrect playback under the item that
    // replaced this one.
    expect(factory.created.first.playCount, 0);
    expect(factory.created.first.disposeCount, greaterThanOrEqualTo(1));
  });

  testWidgets('a video that fails to initialize shows an error, not a black box', (tester) async {
    factory.configure = (playback) =>
        playback.initializeError = Exception('codec unavailable');

    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('feed_video_error')), findsOneWidget);
    expect(find.text('This video could not be played'), findsOneWidget);
    expect(factory.last.disposeCount, 1, reason: 'a failed controller is still released');
  });

  testWidgets('the sound choice is saved and used by the next video', (tester) async {
    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();
    expect(factory.last.volume, 0);

    await tester.tap(find.byKey(const Key('feed_video_mute')));
    await tester.pumpAndSettle();
    expect(prefs.feedMuted, isFalse, reason: 'remembered across posts and visits');

    // A different post's video starts with sound.
    await tester.pumpWidget(subject(isActive: true, url: 'https://v/b.mp4'));
    await tester.pumpAndSettle();
    expect(factory.last.url, 'https://v/b.mp4');
    expect(factory.last.volume, 1);
  });

  testWidgets('a browser that blocks sound autoplay falls back to muted', (tester) async {
    await usePrefs({'moco_feed_muted': false});
    factory.configure = (playback) => playback.blockUnmutedAutoplay = true;

    await tester.pumpWidget(subject(isActive: true));
    await tester.pumpAndSettle();

    expect(factory.count, 2, reason: 'restarted once, muted');
    expect(factory.created.first.disposeCount, 1);
    expect(factory.last.volume, 0);
    expect(factory.last.isPlaying, isTrue);
    expect(find.byKey(const Key('feed_video_error')), findsNothing);
    expect(prefs.feedMuted, isFalse, reason: 'the saved choice is not overwritten');

    // The next tap is the gesture the browser wanted: sound comes on.
    await tester.tap(find.byKey(const Key('feed_video_mute')));
    await tester.pumpAndSettle();
    expect(factory.last.volume, 1);
  });

  testWidgets('without looping, the end of the clip is reported once', (tester) async {
    var completed = 0;
    await tester.pumpWidget(
      subject(isActive: true, loop: false, onCompleted: () => completed += 1),
    );
    await tester.pumpAndSettle();
    expect(factory.last.looping, isFalse);

    factory.last.finish();
    await tester.pump();
    factory.last.finish();
    await tester.pump();
    expect(completed, 1);
  });
}
