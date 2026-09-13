import '../../shared/models/notification.dart';
import 'api_client.dart';

class NotificationsApi {
  const NotificationsApi(this._client);

  final ApiClient _client;

  /// `GET /notifications` — newest-first page plus a total unread count.
  Future<NotificationPage> list({int limit = 30, int? before}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/notifications',
        queryParameters: {'limit': limit, if (before != null) 'before': before},
      ),
      (data) => NotificationPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /notifications/:id/read`. Idempotent.
  Future<void> markRead(int id) {
    return _client.request(
      () => _client.dio.post<dynamic>('/notifications/$id/read'),
      (_) {},
    );
  }

  /// `POST /notifications/read-all`.
  Future<void> markAllRead() {
    return _client.request(
      () => _client.dio.post<dynamic>('/notifications/read-all'),
      (_) {},
    );
  }

  /// `DELETE /notifications/:id`.
  Future<void> delete(int id) {
    return _client.request(
      () => _client.dio.delete<dynamic>('/notifications/$id'),
      (_) {},
    );
  }
}
