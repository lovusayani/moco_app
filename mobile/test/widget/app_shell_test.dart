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

    test('Discovery and Wallet are real; the rest are placeholders', () {
      expect(AppShellTab.discovery.isPlaceholder, isFalse);
      expect(AppShellTab.wallet.isPlaceholder, isFalse);
      for (final tab in AppShellTab.values.where(
        (t) => t != AppShellTab.discovery && t != AppShellTab.wallet,
      )) {
        expect(
          tab.isPlaceholder,
          isTrue,
          reason: '${tab.label} is not built yet',
        );
      }
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
    expect(find.textContaining('Phase 2'), findsOneWidget);
  });

  testWidgets('the chats placeholder points at Phase 3', (tester) async {
    await tester.pumpWidget(
      wrapWidget(const PlaceholderTabScreen(tab: AppShellTab.chats)),
    );
    await tester.pump();

    expect(find.textContaining('Phase 3'), findsOneWidget);
  });
}
