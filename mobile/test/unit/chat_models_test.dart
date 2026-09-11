import 'package:flutter_test/flutter_test.dart';
import 'package:moco/shared/models/chat.dart';

void main() {
  group('ChatMessage.fromJson', () {
    test('parses a text message', () {
      final message = ChatMessage.fromJson({
        'id': 5,
        'conversationId': 2,
        'senderId': 7,
        'type': 'text',
        'body': 'hi',
        'mediaUrl': null,
        'readAt': null,
        'createdAt': '2026-01-01T10:00:00.000Z',
        'reactions': [],
      });

      expect(message.type, MessageType.text);
      expect(message.body, 'hi');
      expect(message.isImage, isFalse);
      expect(message.isSentBy(7), isTrue);
      expect(message.isSentBy(9), isFalse);
    });

    test('parses an image message with reactions', () {
      final message = ChatMessage.fromJson({
        'id': 9,
        'conversationId': 2,
        'senderId': 3,
        'type': 'image',
        'body': null,
        'mediaUrl': 'https://signed.example/photo.jpg',
        'createdAt': '2026-01-01T10:00:00.000Z',
        'reactions': [
          {'userId': 1, 'emoji': '❤️'},
          {'userId': 2, 'emoji': '😂'},
        ],
      });

      expect(message.isImage, isTrue);
      expect(message.mediaUrl, 'https://signed.example/photo.jpg');
      expect(message.reactions.length, 2);
      expect(message.reactionBy(1)?.emoji, '❤️');
      expect(message.reactionBy(99), isNull);
    });

    test('an unrecognised type falls back to text', () {
      final message = ChatMessage.fromJson({
        'id': 1,
        'senderId': 1,
        'type': 'video',
        'createdAt': '2026-01-01T10:00:00.000Z',
      });
      expect(message.type, MessageType.text);
    });
  });

  test('withReaction replaces rather than duplicates a user\'s existing reaction', () {
    final base = ChatMessage(
      id: 1,
      conversationId: 1,
      senderId: 1,
      type: MessageType.text,
      body: 'hi',
      createdAt: DateTime(2026, 1, 1),
      reactions: const [MessageReaction(userId: 5, emoji: '👍')],
    );

    final changed = base.withReaction(userId: 5, emoji: '❤️');
    expect(changed.reactions.length, 1);
    expect(changed.reactions.single.emoji, '❤️');

    final removed = changed.withReaction(userId: 5, emoji: null);
    expect(removed.reactions, isEmpty);

    final untouched = base.withReaction(userId: 6, emoji: '😂');
    expect(untouched.reactions.length, 2);
  });

  group('MessageHistoryPage.fromJson', () {
    test('parses messages and nextCursor', () {
      final page = MessageHistoryPage.fromJson({
        'messages': [
          {
            'id': 1,
            'senderId': 1,
            'type': 'text',
            'body': 'a',
            'createdAt': '2026-01-01T10:00:00.000Z',
          },
        ],
        'nextCursor': 1,
      });
      expect(page.messages.length, 1);
      expect(page.hasMore, isTrue);
    });

    test('no nextCursor means no more history', () {
      final page = MessageHistoryPage.fromJson({'messages': [], 'nextCursor': null});
      expect(page.hasMore, isFalse);
    });
  });

  group('Conversation.fromJson', () {
    test('parses the counterparty and unread count', () {
      final conversation = Conversation.fromJson({
        'id': 4,
        'counterparty': {'id': 8, 'name': 'Priya', 'avatarUrl': 'https://x/a.jpg'},
        'lastMessage': 'hey',
        'lastMessageAt': '2026-01-01T10:00:00.000Z',
        'unreadCount': 3,
      });

      expect(conversation.counterpartyId, 8);
      expect(conversation.displayName, 'Priya');
      expect(conversation.hasUnread, isTrue);
    });

    test('falls back to a generic name when none is set', () {
      final conversation = Conversation.fromJson({
        'id': 4,
        'counterparty': {'id': 8},
        'unreadCount': 0,
      });
      expect(conversation.displayName, 'Moco user');
      expect(conversation.hasUnread, isFalse);
    });
  });

  group('socket event parsing', () {
    test('ChatMessageEvent.toMessage carries the type through', () {
      final event = ChatMessageEvent.fromJson({
        'conversationId': 1,
        'messageId': 9,
        'senderId': 3,
        'type': 'image',
        'body': null,
        'mediaUrl': 'https://signed.example/x.jpg',
        'createdAt': '2026-01-01T10:00:00.000Z',
      });
      final message = event.toMessage();
      expect(message.isImage, isTrue);
      expect(message.id, 9);
    });

    test('ChatReactionEvent parses a null emoji as removal', () {
      final event = ChatReactionEvent.fromJson({
        'conversationId': 1,
        'messageId': 9,
        'userId': 3,
        'emoji': null,
      });
      expect(event.emoji, isNull);
    });
  });
}
