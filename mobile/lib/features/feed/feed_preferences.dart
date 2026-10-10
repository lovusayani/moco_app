import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/storage/secure_store.dart';

/// Feed sound, shared by every post.
///
/// [preferMuted] is the user's choice, persisted in [AppPreferences] so it
/// carries across posts and visits. [autoplayBlocked] is the browser's: a
/// page that has not had a user gesture yet may refuse to start a video with
/// sound. When that happens the feed falls back to muted for the rest of the
/// session rather than showing a broken video — without overwriting the
/// user's saved choice. The next tap on the sound control is itself the
/// gesture the browser wanted, so it clears the block.
class FeedMuteState {
  const FeedMuteState({
    required this.preferMuted,
    this.autoplayBlocked = false,
  });

  final bool preferMuted;
  final bool autoplayBlocked;

  /// What the player should actually do.
  bool get muted => preferMuted || autoplayBlocked;
}

class FeedMuteController extends StateNotifier<FeedMuteState> {
  FeedMuteController(this._prefs)
    : super(FeedMuteState(preferMuted: _prefs.feedMuted));

  final AppPreferences _prefs;

  /// The sound control: flips what the user hears, and remembers it.
  Future<void> toggle() async {
    final muted = !state.muted;
    state = FeedMuteState(preferMuted: muted);
    await _prefs.setFeedMuted(muted);
  }

  /// The browser refused to start a video with sound.
  void markAutoplayBlocked() {
    if (state.autoplayBlocked) return;
    state = FeedMuteState(
      preferMuted: state.preferMuted,
      autoplayBlocked: true,
    );
  }
}

final feedMuteProvider =
    StateNotifierProvider<FeedMuteController, FeedMuteState>(
      (ref) => FeedMuteController(ref.watch(appPreferencesProvider)),
    );

/// Profile → App settings → Feed auto-scroll. Off by default.
///
/// This is only the saved setting. Pausing auto-scroll because the user
/// touched the feed is per visit and lives in the Feed screen — it never
/// writes here, so a touch can never turn the setting off.
class FeedAutoScrollController extends StateNotifier<bool> {
  FeedAutoScrollController(this._prefs) : super(_prefs.feedAutoScroll);

  final AppPreferences _prefs;

  Future<void> setEnabled(bool enabled) async {
    if (enabled == state) return;
    state = enabled;
    await _prefs.setFeedAutoScroll(enabled);
  }
}

final feedAutoScrollProvider =
    StateNotifierProvider<FeedAutoScrollController, bool>(
      (ref) => FeedAutoScrollController(ref.watch(appPreferencesProvider)),
    );
