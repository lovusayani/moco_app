import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/notifications_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/notifications/notifications_screen.dart';
import 'package:moco/shared/models/notification.dart';

class _MockNotificationsApi extends Mock implements NotificationsApi {}

AppNotification _n(int id, {String type = 'kyc_approved', bool read = false}) => AppNotification(
  id: id,
  type: type,
  title: 'Notification $id',
  body: 'Body $id',
  read: read,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  late _MockNotificationsApi api;

  setUp(() {
    api = _MockNotificationsApi();
  });

  Widget subject() {
    final router = GoRouter(
      initialLocation: '/notifications',
      routes: [
        GoRoute(
          path: '/notifications',
          builder: (_, __) => const NotificationsScreen(),
        ),
        GoRoute(path: '/profile', builder: (_, __) => const Scaffold(body: Text('profile screen'))),
        GoRoute(
          path: '/profile/ledger/earnings',
          builder: (_, __) => const Scaffold(body: Text('earnings ledger screen')),
        ),
      ],
    );

    return ProviderScope(
      overrides: [notificationsApiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: MocoTheme.dark, routerConfig: router),
    );
  }

  testWidgets('shows an empty state with no notifications', (tester) async {
    when(() => api.list()).thenAnswer((_) async => const NotificationPage());

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notifications_empty')), findsOneWidget);
  });

  testWidgets('shows an error with retry on failure', (tester) async {
    when(() => api.list()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'No internet connection'),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notifications_error')), findsOneWidget);

    when(() => api.list()).thenAnswer((_) async => NotificationPage(notifications: [_n(1)]));
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Notification 1'), findsOneWidget);
  });

  testWidgets('renders notifications and an unread indicator', (tester) async {
    when(() => api.list()).thenAnswer(
      (_) async => NotificationPage(
        notifications: [_n(2), _n(1, read: true)],
        unreadCount: 1,
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.text('Notification 2'), findsOneWidget);
    expect(find.text('Notification 1'), findsOneWidget);
    expect(find.byKey(const Key('notification_unread_dot')), findsOneWidget);
    expect(find.byKey(const Key('notifications_mark_all_read')), findsOneWidget);
  });

  testWidgets('no mark-all-read button when everything is already read', (tester) async {
    when(() => api.list()).thenAnswer(
      (_) async => NotificationPage(notifications: [_n(1, read: true)], unreadCount: 0),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notifications_mark_all_read')), findsNothing);
  });

  testWidgets('tapping a KYC notification marks it read and opens Profile', (tester) async {
    when(() => api.list()).thenAnswer(
      (_) async => NotificationPage(notifications: [_n(1, type: 'kyc_approved')], unreadCount: 1),
    );
    when(() => api.markRead(1)).thenAnswer((_) async {});

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notification_row_1')));
    await tester.pumpAndSettle();

    verify(() => api.markRead(1)).called(1);
    expect(find.text('profile screen'), findsOneWidget);
  });

  testWidgets('tapping a payout notification opens the earnings ledger', (tester) async {
    when(() => api.list()).thenAnswer(
      (_) async => NotificationPage(notifications: [_n(1, type: 'payout_approved')], unreadCount: 1),
    );
    when(() => api.markRead(1)).thenAnswer((_) async {});

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notification_row_1')));
    await tester.pumpAndSettle();

    expect(find.text('earnings ledger screen'), findsOneWidget);
  });

  testWidgets('swiping deletes the notification', (tester) async {
    when(() => api.list()).thenAnswer(
      (_) async => NotificationPage(notifications: [_n(1), _n(2)], unreadCount: 2),
    );
    when(() => api.delete(1)).thenAnswer((_) async {});

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const ValueKey('notification_1')), const Offset(-500, 0));
    await tester.pumpAndSettle();

    verify(() => api.delete(1)).called(1);
    expect(find.text('Notification 1'), findsNothing);
    expect(find.text('Notification 2'), findsOneWidget);
  });

  testWidgets('mark-all-read clears every unread indicator', (tester) async {
    when(() => api.list()).thenAnswer(
      (_) async => NotificationPage(notifications: [_n(2), _n(1)], unreadCount: 2),
    );
    when(() => api.markAllRead()).thenAnswer((_) async {});

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notifications_mark_all_read')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notification_unread_dot')), findsNothing);
    verify(() => api.markAllRead()).called(1);
  });
}
