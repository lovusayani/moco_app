import 'package:flutter_test/flutter_test.dart';
import 'package:moco/features/app_shell/app_shell.dart';

void main() {
  group('AppShellTab', () {
    test('exposes the five destinations in the designed order', () {
      expect(AppShellTab.values.map((t) => t.label).toList(), [
        'Discover',
        'Feed',
        'Chats',
        'Wallet',
        'Profile',
      ]);
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
