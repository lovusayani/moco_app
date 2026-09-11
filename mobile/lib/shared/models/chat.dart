/// Chat domain models, mirroring docs/API.md's Chat section exactly. A
/// message's reactions and read state are always what the server last said —
/// nothing here is inferred or computed client-side.
library;

enum MessageType {
  text,
  image;

  static MessageType fromJson(String? value) =>
      value == 'image' ? MessageType.image : MessageType.text;
}

/// One reaction to a message.
class MessageReaction {
  const MessageReaction({required this.userId, required this.emoji});

  final int userId;
  final String emoji;

  factory MessageReaction.fromJson(Map<String, dynamic> json) {
    return MessageReaction(
      userId: (json['userId'] as num).toInt(),
      emoji: json['emoji'] as String? ?? '',
    );
  }
}

/// A single chat message.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    this.body,
    this.mediaUrl,
    this.readAt,
    required this.createdAt,
    this.reactions = const [],
  });

  final int id;
  final int conversationId;
  final int senderId;
  final MessageType type;
  final String? body;
  final String? mediaUrl;
  final DateTime? readAt;
  final DateTime createdAt;
  final List<MessageReaction> reactions;

  bool get isImage => type == MessageType.image;

  bool isSentBy(int userId) => senderId == userId;

  /// This viewer's own reaction, if any — at most one per user per message.
  MessageReaction? reactionBy(int userId) {
    for (final r in reactions) {
      if (r.userId == userId) return r;
    }
    return null;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final reactionsRaw = json['reactions'];
    return ChatMessage(
      id: (json['id'] as num).toInt(),
      conversationId: (json['conversationId'] as num?)?.toInt() ?? 0,
      senderId: (json['senderId'] as num).toInt(),
      type: MessageType.fromJson(json['type'] as String?),
      body: json['body'] as String?,
      mediaUrl: json['mediaUrl'] as String?,
      readAt: json['readAt'] == null
          ? null
          : DateTime.tryParse(json['readAt'] as String),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      reactions: reactionsRaw is List
          ? reactionsRaw
                .whereType<Map>()
                .map((e) => MessageReaction.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
    );
  }

  /// Applies a live reaction update from the socket without refetching.
  ChatMessage withReaction({required int userId, required String? emoji}) {
    final next = reactions.where((r) => r.userId != userId).toList();
    if (emoji != null) next.add(MessageReaction(userId: userId, emoji: emoji));
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      body: body,
      mediaUrl: mediaUrl,
      readAt: readAt,
      createdAt: createdAt,
      reactions: next,
    );
  }

  ChatMessage markRead() => ChatMessage(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    type: type,
    body: body,
    mediaUrl: mediaUrl,
    readAt: readAt ?? DateTime.now(),
    createdAt: createdAt,
    reactions: reactions,
  );
}

/// A page of message history (`GET /chat/:userId/messages`), oldest first.
class MessageHistoryPage {
  const MessageHistoryPage({this.messages = const [], this.nextCursor});

  final List<ChatMessage> messages;
  final int? nextCursor;

  bool get hasMore => nextCursor != null;

  factory MessageHistoryPage.fromJson(Map<String, dynamic> json) {
    final raw = json['messages'];
    return MessageHistoryPage(
      messages: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      nextCursor: (json['nextCursor'] as num?)?.toInt(),
    );
  }
}

/// One row of the Chats list (`GET /chat`).
class Conversation {
  const Conversation({
    required this.id,
    required this.counterpartyId,
    this.counterpartyName,
    this.counterpartyAvatarUrl,
    this.lastMessage,
    this.lastMessageAt,
    this.unreadCount = 0,
  });

  final int id;
  final int counterpartyId;
  final String? counterpartyName;
  final String? counterpartyAvatarUrl;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final int unreadCount;

  String get displayName =>
      (counterpartyName?.trim().isNotEmpty ?? false) ? counterpartyName!.trim() : 'Moco user';

  bool get hasUnread => unreadCount > 0;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final counterparty = Map<String, dynamic>.from(
      json['counterparty'] as Map? ?? const {},
    );
    return Conversation(
      id: (json['id'] as num).toInt(),
      counterpartyId: (counterparty['id'] as num?)?.toInt() ?? 0,
      counterpartyName: counterparty['name'] as String?,
      counterpartyAvatarUrl: counterparty['avatarUrl'] as String?,
      lastMessage: json['lastMessage'] as String?,
      lastMessageAt: json['lastMessageAt'] == null
          ? null
          : DateTime.tryParse(json['lastMessageAt'] as String),
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  Conversation copyWith({
    String? lastMessage,
    DateTime? lastMessageAt,
    int? unreadCount,
  }) {
    return Conversation(
      id: id,
      counterpartyId: counterpartyId,
      counterpartyName: counterpartyName,
      counterpartyAvatarUrl: counterpartyAvatarUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

/// `chat:message` socket payload.
class ChatMessageEvent {
  const ChatMessageEvent({
    required this.conversationId,
    required this.messageId,
    required this.senderId,
    required this.type,
    this.body,
    this.mediaUrl,
    required this.createdAt,
  });

  final int conversationId;
  final int messageId;
  final int senderId;
  final MessageType type;
  final String? body;
  final String? mediaUrl;
  final DateTime createdAt;

  factory ChatMessageEvent.fromJson(Map<String, dynamic> json) {
    return ChatMessageEvent(
      conversationId: (json['conversationId'] as num).toInt(),
      messageId: (json['messageId'] as num).toInt(),
      senderId: (json['senderId'] as num).toInt(),
      type: MessageType.fromJson(json['type'] as String?),
      body: json['body'] as String?,
      mediaUrl: json['mediaUrl'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  ChatMessage toMessage() => ChatMessage(
    id: messageId,
    conversationId: conversationId,
    senderId: senderId,
    type: type,
    body: body,
    mediaUrl: mediaUrl,
    createdAt: createdAt,
  );
}

/// `chat:reaction` socket payload. `emoji: null` means the reaction was removed.
class ChatReactionEvent {
  const ChatReactionEvent({
    required this.conversationId,
    required this.messageId,
    required this.userId,
    this.emoji,
  });

  final int conversationId;
  final int messageId;
  final int userId;
  final String? emoji;

  factory ChatReactionEvent.fromJson(Map<String, dynamic> json) {
    return ChatReactionEvent(
      conversationId: (json['conversationId'] as num).toInt(),
      messageId: (json['messageId'] as num).toInt(),
      userId: (json['userId'] as num).toInt(),
      emoji: json['emoji'] as String?,
    );
  }
}

/// Response of `POST /chat/media/upload-url`.
class ChatUploadAuthorization {
  const ChatUploadAuthorization({
    required this.path,
    required this.uploadUrl,
    required this.token,
    required this.maxBytes,
  });

  final String path;
  final String uploadUrl;
  final String token;
  final int maxBytes;

  factory ChatUploadAuthorization.fromJson(Map<String, dynamic> json) {
    return ChatUploadAuthorization(
      path: json['path'] as String? ?? '',
      uploadUrl: json['uploadUrl'] as String? ?? '',
      token: json['token'] as String? ?? '',
      maxBytes: (json['maxBytes'] as num?)?.toInt() ?? 8 * 1024 * 1024,
    );
  }
}
