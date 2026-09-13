/// Notification domain models, mirroring `GET /api/notifications` exactly.
library;

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    this.body,
    this.data = const {},
    this.read = false,
    required this.createdAt,
  });

  final int id;
  final String type;
  final String title;
  final String? body;
  final Map<String, dynamic> data;
  final bool read;
  final DateTime createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: (json['id'] as num).toInt(),
      type: json['type'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String?,
      data: json['data'] is Map ? Map<String, dynamic>.from(json['data'] as Map) : const {},
      read: json['read'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  AppNotification markRead() => AppNotification(
    id: id,
    type: type,
    title: title,
    body: body,
    data: data,
    read: true,
    createdAt: createdAt,
  );
}

class NotificationPage {
  const NotificationPage({
    this.notifications = const [],
    this.nextCursor,
    this.unreadCount = 0,
  });

  final List<AppNotification> notifications;
  final int? nextCursor;
  final int unreadCount;

  bool get hasMore => nextCursor != null;

  factory NotificationPage.fromJson(Map<String, dynamic> json) {
    final raw = json['notifications'];
    return NotificationPage(
      notifications: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      nextCursor: (json['nextCursor'] as num?)?.toInt(),
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }
}
