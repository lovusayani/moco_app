import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/notifications_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/notifications/notifications_controller.dart';
import 'package:moco/shared/models/notification.dart';

class _MockNotificationsApi extends Mock implements NotificationsApi {}

AppNotification _n(int id, {bool read = false}) => AppNotification(
  id: id,
  type: 'kyc_approved',
  title: 'N$id',
  read: read,
  createdAt: DateTime(2026, 1, 1),
);

NotificationPage _page(List<AppNotification> items, {int? nextCursor, int? unreadCount}) =>
    NotificationPage(
      notifications: items,
      nextCursor: nextCursor,
      unreadCount: unreadCount ?? items.where((n) => !n.read).length,
    );

void main() {
  late _MockNotificationsApi api;

  setUp(() => api = _MockNotificationsApi());

  Future<NotificationsController> loaded() async {
    final controller = NotificationsController(api);
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  test('loads the first page with its unread count', () async {
    when(() => api.list()).thenAnswer((_) async => _page([_n(3), _n(2)]));

    final controller = await loaded();

    expect(controller.state.notifications.map((n) => n.id), [3, 2]);
    expect(controller.state.unreadCount, 2);
    controller.dispose();
  });

  test('an empty inbox is not an error', () async {
    when(() => api.list()).thenAnswer((_) async => _page([]));

    final controller = await loaded();

    expect(controller.state.isEmpty, isTrue);
    controller.dispose();
  });

  test('a failed load is fatal only when nothing is on screen', () async {
    when(() => api.list()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );

    final controller = await loaded();

    expect(controller.state.isFatalError, isTrue);
    controller.dispose();
  });

  test('loadMore appends via the cursor and dedupes', () async {
    when(() => api.list()).thenAnswer((_) async => _page([_n(5), _n(4)], nextCursor: 4));
    final controller = await loaded();

    when(() => api.list(before: 4)).thenAnswer((_) async => _page([_n(4), _n(3)]));
    await controller.loadMore();

    expect(controller.state.notifications.map((n) => n.id), [5, 4, 3]);
    controller.dispose();
  });

  test('markRead flips one notification and drops the unread count', () async {
    when(() => api.list()).thenAnswer(
      (_) async => _page([_n(2), _n(1)], unreadCount: 2),
    );
    final controller = await loaded();

    when(() => api.markRead(2)).thenAnswer((_) async {});
    await controller.markRead(2);

    expect(controller.state.notifications.first.read, isTrue);
    expect(controller.state.unreadCount, 1);
    verify(() => api.markRead(2)).called(1);
    controller.dispose();
  });

  test('markRead on an already-read notification does nothing', () async {
    when(() => api.list()).thenAnswer((_) async => _page([_n(1, read: true)], unreadCount: 0));
    final controller = await loaded();

    await controller.markRead(1);

    verifyNever(() => api.markRead(any()));
    controller.dispose();
  });

  test('markAllRead clears the whole list and the badge', () async {
    when(() => api.list()).thenAnswer((_) async => _page([_n(2), _n(1)], unreadCount: 2));
    final controller = await loaded();

    when(() => api.markAllRead()).thenAnswer((_) async {});
    await controller.markAllRead();

    expect(controller.state.notifications.every((n) => n.read), isTrue);
    expect(controller.state.unreadCount, 0);
    controller.dispose();
  });

  test('delete removes the notification immediately', () async {
    when(() => api.list()).thenAnswer((_) async => _page([_n(2), _n(1)], unreadCount: 2));
    final controller = await loaded();

    when(() => api.delete(2)).thenAnswer((_) async {});
    await controller.delete(2);

    expect(controller.state.notifications.map((n) => n.id), [1]);
    expect(controller.state.unreadCount, 1);
    controller.dispose();
  });

  test('a failed delete restores the notification and the unread count', () async {
    when(() => api.list()).thenAnswer((_) async => _page([_n(2), _n(1)], unreadCount: 2));
    final controller = await loaded();

    when(() => api.delete(2)).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );
    await controller.delete(2);

    expect(controller.state.notifications.map((n) => n.id), [2, 1]);
    expect(controller.state.unreadCount, 2);
    controller.dispose();
  });
}
