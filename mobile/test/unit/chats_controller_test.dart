import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/realtime/socket_service.dart';
import 'package:moco/features/chats/chats_controller.dart';
import 'package:moco/shared/models/chat.dart';

class _MockChatApi extends Mock implements ChatApi {}

class _MockSocketService extends Mock implements SocketService {}

const _conversation = Conversation(
  id: 1,
  counterpartyId: 7,
  counterpartyName: 'Priya',
  unreadCount: 0,
);

void main() {
  late _MockChatApi api;
  late _MockSocketService socket;
  late Map<String, void Function(dynamic)> handlers;

  void emit(String event, Map<String, dynamic> payload) => handlers[event]?.call(payload);

  setUp(() {
    api = _MockChatApi();
    socket = _MockSocketService();
    handlers = {};
    when(() => socket.on(any(), any())).thenAnswer((invocation) {
      final event = invocation.positionalArguments[0] as String;
      final handler = invocation.positionalArguments[1] as void Function(dynamic);
      handlers[event] = handler;
      return () {};
    });
    when(() => api.conversations()).thenAnswer((_) async => [_conversation]);
  });

  test('load() populates the list', () async {
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.conversations.length, 1);
    expect(controller.state.isLoading, isFalse);
    controller.dispose();
  });

  test('an empty list reports isEmpty once loading finishes', () async {
    when(() => api.conversations()).thenAnswer((_) async => []);
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.isEmpty, isTrue);
    controller.dispose();
  });

  test('an incoming message from a known conversation bumps it to the top and increments unread', () async {
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);

    emit('chat:message', {
      'conversationId': 1,
      'messageId': 55,
      'senderId': 7,
      'type': 'text',
      'body': 'hello there',
      'createdAt': '2026-01-01T10:00:00.000Z',
    });

    expect(controller.state.conversations.first.lastMessage, 'hello there');
    expect(controller.state.conversations.first.unreadCount, 1);
    controller.dispose();
  });

  test('an image message shows "Photo" as the preview, not a blank body', () async {
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);

    emit('chat:message', {
      'conversationId': 1,
      'messageId': 56,
      'senderId': 7,
      'type': 'image',
      'mediaUrl': 'https://signed.example/x.jpg',
      'createdAt': '2026-01-01T10:00:00.000Z',
    });

    expect(controller.state.conversations.first.lastMessage, 'Photo');
    controller.dispose();
  });

  test('an incoming message from an unknown sender triggers a reload rather than guessing their name', () async {
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);

    emit('chat:message', {
      'conversationId': 2,
      'messageId': 99,
      'senderId': 999,
      'type': 'text',
      'body': 'first message ever',
      'createdAt': '2026-01-01T10:00:00.000Z',
    });
    await Future<void>.delayed(Duration.zero);

    verify(() => api.conversations()).called(2); // initial load + reload
    controller.dispose();
  });

  test('markRead clears the unread count for one conversation', () async {
    when(() => api.conversations()).thenAnswer(
      (_) async => [_conversation.copyWith(unreadCount: 3)],
    );
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.conversations.first.unreadCount, 3);

    controller.markRead(7);
    expect(controller.state.conversations.first.unreadCount, 0);
    controller.dispose();
  });

  test('bumpLastMessage updates the preview after a successful send', () async {
    final controller = ChatsController(api, socket);
    await Future<void>.delayed(Duration.zero);

    controller.bumpLastMessage(
      counterpartyId: 7,
      preview: 'sent from me',
      at: DateTime(2026, 1, 1),
    );

    expect(controller.state.conversations.first.lastMessage, 'sent from me');
    controller.dispose();
  });
}
