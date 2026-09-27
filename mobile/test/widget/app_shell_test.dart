import 'package:flutter_test/flutter_test.dart';
import 'package:moco/features/app_shell/app_shell.dart';

void main() {
  group('AppShellTab', () {
    test('exposes the five destinations in the approved final order', () {
      expect(AppShellTab.values.map((t) => t.label).toList(), [
        'Discover',
        'Wallet',
        'Feed',
        'Chat',
        'Profile',
      ]);
    });

    test('Feed is the center tab and Chat sits beside Profile', () {
      final values = AppShellTab.values;
      expect(values[values.length ~/ 2], AppShellTab.feed);
      expect(values[values.length - 2], AppShellTab.chats);
      expect(values.last, AppShellTab.profile);
    });

    test('all tabs are real; none are placeholders', () {
      for (final tab in AppShellTab.values) {
        expect(tab.isPlaceholder, isFalse, reason: '${tab.label} should be real');
      }
    });

    test('every tab has a unique route', () {
      final paths = AppShellTab.values.map((t) => t.path).toSet();
      expect(paths.length, AppShellTab.values.length);
    });
  });
}
