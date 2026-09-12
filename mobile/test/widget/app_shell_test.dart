import 'package:flutter_test/flutter_test.dart';
import 'package:moco/features/app_shell/app_shell.dart';

import '../support/harness.dart';

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

    test('only Profile is still a placeholder', () {
      const real = {
        AppShellTab.discovery,
        AppShellTab.feed,
        AppShellTab.chats,
        AppShellTab.wallet,
      };
      for (final tab in real) {
        expect(tab.isPlaceholder, isFalse, reason: '${tab.label} should be real');
      }
      expect(AppShellTab.profile.isPlaceholder, isTrue);
    });

    test('every tab has a unique route', () {
      final paths = AppShellTab.values.map((t) => t.path).toSet();
      expect(paths.length, AppShellTab.values.length);
    });
  });

  testWidgets('a placeholder tab names its phase rather than inventing UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapWidget(const PlaceholderTabScreen(tab: AppShellTab.profile)),
    );
    await tester.pump();

    expect(find.text('Profile'), findsOneWidget);
    expect(find.textContaining('a later phase'), findsOneWidget);
  });
}
