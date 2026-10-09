import 'package:flutter_test/flutter_test.dart';
import 'package:moco/shared/models/live.dart';

void main() {
  test('the player is available only with an https official script', () {
    final on = LivePlayerConfig.fromJson({
      'type': 'stripchat-player',
      'userId': 'aff',
      'strict': 1,
      'autoplay': 'playButton',
      'scriptUrl': 'https://creative.whitetrafsa.com/widgets/Player/lib.js',
      'framePath': '/live/player-frame',
    })!;
    expect(on.available, isTrue);
    expect(on.framePath, '/live/player-frame');
    expect(on.autoplay, 'playButton');

    final noScript = LivePlayerConfig.fromJson({
      'userId': 'aff',
      'scriptUrl': null,
    })!;
    expect(noScript.available, isFalse);

    final insecure = LivePlayerConfig.fromJson({
      'userId': 'aff',
      'scriptUrl': 'http://creative.whitetrafsa.com/widgets/Player/lib.js',
    })!;
    expect(insecure.available, isFalse);
  });

  test('the frame is always a path on the API, never a URL from the network', () {
    for (final bad in [
      'https://evil.example/frame',
      '//evil.example/frame',
      'javascript:alert(1)',
      '/live/player-frame?x=<script>',
    ]) {
      final c = LivePlayerConfig.fromJson({
        'userId': 'aff',
        'scriptUrl': 'https://creative.whitetrafsa.com/widgets/Player/lib.js',
        'framePath': bad,
      })!;
      expect(c.framePath, '/live/player-frame', reason: bad);
    }
  });

  test('no player block → no player', () {
    expect(LivePlayerConfig.fromJson(null), isNull);
    expect(LivePlayerConfig.fromJson({'scriptUrl': 'https://x'}), isNull);
  });
}
