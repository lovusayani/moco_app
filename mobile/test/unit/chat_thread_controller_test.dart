import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/realtime/socket_service.dart';
import 'package:moco/features/chat_thread/chat_thread_controller.dart';
import 'package:moco/shared/models/chat.dart';

class _MockChatApi extends Mock implements ChatApi {}

class _MockSocketService extends Mock implements SocketService {}

ChatMessage _message(int id, {int senderId = 7, String body = 'hi', List<MessageReaction> reactions = const []}) {
  return ChatMessage(
    id: id,
    conversationId: 1,
    senderId: senderId,
    type: MessageType.text,
    body: body,
    createdAt: DateTime(2026, 1, 1, 10, id),
    reactions: reactions,
  );
}

void main() {
  late _MockChatApi api;
  late _MockSocketService socket;
  late Map<String, void Function(dynamic)> handlers;
  late ValueNotifier<SocketStatus> socketStatus;
  late List<int> readCalls;
  late List<String> sentPreviews;

  void emit(String event, Map<String, dynamic> payload) => handlers[event]?.call(payload);

  ChatThreadController build({int counterpartyId = 7}) {
    return ChatThreadController(
      api,
      socket,
      counterpartyId,
      onRead: (id) => readCalls.add(id),
      onSent: ({required counterpartyId, required preview, required at}) =>
          sentPreviews.add(preview),
    );
  }

  setUp(() {
    api = _MockChatApi();
    socket = _MockSocketService();
    handlers = {};
    socketStatus = ValueNotifier(SocketStatus.connected);
    readCalls = [];
    sentPreviews = [];

    when(() => socket.status).thenReturn(socketStatus);
    when(() => socket.on(any(), any())).thenAnswer((invocation) {
      final event = invocation.positionalArguments[0] as String;
      final handler = invocation.positionalArguments[1] as void Function(dynamic);
      handlers[event] = handler;
      return () {};
    });
    when(() => api.messages(any())).thenAnswer(
      (_) async => MessageHistoryPage(
        messages: [_message(1), _message(2)],
        nextCursor: 1, // there is older history, matching a real page
      ),
    );
  });

  test('load() populates messages oldest-first and marks the conversation read', () async {
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.messages.map((m) => m.id).toList(), [1, 2]);
    expect(readCalls, [7]);
    controller.dispose();
  });

  test('loadOlder prepends without duplicating overlapping ids', () async {
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    when(() => api.messages(any(), before: 1)).thenAnswer(
      (_) async => MessageHistoryPage(messages: [_message(0)], nextCursor: null),
    );
    await controller.loadOlder();

    expect(controller.state.messages.map((m) => m.id).toList(), [0, 1, 2]);
    expect(controller.state.hasMoreOlder, isFalse);
    controller.dispose();
  });

  test('sendText succeeds, appends the message, and notifies the list', () async {
    when(() => api.sendText(7, 'hello')).thenAnswer((_) async => _message(3, senderId: 1, body: 'hello'));
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    await controller.sendText('hello');

    expect(controller.state.messages.any((m) => m.id == 3), isTrue);
    expect(controller.state.isSending, isFalse);
    expect(sentPreviews, ['hello']);
    controller.dispose();
  });

  test('sendText surfaces a failure (e.g. blocked) without adding a message', () async {
    when(() => api.sendText(7, 'this should not send')).thenThrow(
      const ApiException(kind: ApiErrorKind.forbidden, message: 'This user is not available'),
    );
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    await controller.sendText('this should not send');

    expect(controller.state.sendError, isNotNull);
    expect(
      controller.state.messages.any((m) => m.body == 'this should not send'),
      isFalse,
    );
    controller.dispose();
  });

  test('an empty or whitespace-only message is never sent', () async {
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    await controller.sendText('   ');

    verifyNever(() => api.sendText(any(), any()));
    controller.dispose();
  });

  test('a second send is ignored while one is already in flight', () async {
    final gate = <Completer<ChatMessage>>[];
    when(() => api.sendText(7, 'a')).thenAnswer((_) {
      final completer = Completer<ChatMessage>();
      gate.add(completer);
      return completer.future;
    });
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    final first = controller.sendText('a');
    final second = controller.sendText('a'); // should be a no-op: still sending

    gate.single.complete(_message(3, senderId: 1, body: 'a'));
    await first;
    await second;

    verify(() => api.sendText(7, 'a')).called(1);
    controller.dispose();
  });

  test('an incoming message from this counterparty refetches and merges', () async {
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    when(() => api.messages(any())).thenAnswer(
      (_) async => MessageHistoryPage(messages: [_message(1), _message(2), _message(3)]),
    );
    emit('chat:message', {
      'conversationId': 1,
      'messageId': 3,
      'senderId': 7,
      'type': 'text',
      'body': 'new',
      'createdAt': '2026-01-01T10:00:00.000Z',
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.messages.length, 3);
    controller.dispose();
  });

  test('an incoming message from someone else is ignored — not this thread', () async {
    final controller = build();
    await Future<void>.delayed(Duration.zero);
    clearInteractions(api); // drop the initial load() call from the count

    emit('chat:message', {
      'conversationId': 9,
      'messageId': 500,
      'senderId': 12345,
      'type': 'text',
      'body': 'not for this thread',
      'createdAt': '2026-01-01T10:00:00.000Z',
    });
    await Future<void>.delayed(Duration.zero);

    verifyNever(() => api.messages(any()));
    controller.dispose();
  });

  test('an incoming reaction event updates the message in place', () async {
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    emit('chat:reaction', {
      'conversationId': 1,
      'messageId': 1,
      'userId': 99,
      'emoji': '🔥',
    });

    final message = controller.state.messages.firstWhere((m) => m.id == 1);
    expect(message.reactionBy(99)?.emoji, '🔥');
    controller.dispose();
  });

  test('toggleReaction sets optimistically and rolls back on failure', () async {
    when(() => api.setReaction(1, '❤️')).thenThrow(
      const ApiException(kind: ApiErrorKind.server, message: 'boom'),
    );
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    final message = controller.state.messages.firstWhere((m) => m.id == 1);
    await controller.toggleReaction(message: message, myUserId: 1, emoji: '❤️');

    final after = controller.state.messages.firstWhere((m) => m.id == 1);
    expect(after.reactionBy(1), isNull, reason: 'a failed set must roll back');
    controller.dispose();
  });

  test('toggleReaction with the same emoji again removes it', () async {
    when(() => api.setReaction(1, '❤️')).thenAnswer((_) async {});
    when(() => api.removeReaction(1)).thenAnswer((_) async {});
    final controller = build();
    await Future<void>.delayed(Duration.zero);

    final message = controller.state.messages.firstWhere((m) => m.id == 1);
    await controller.toggleReaction(message: message, myUserId: 1, emoji: '❤️');
    expect(
      controller.state.messages.firstWhere((m) => m.id == 1).reactionBy(1)?.emoji,
      '❤️',
    );

    final withReaction = controller.state.messages.firstWhere((m) => m.id == 1);
    await controller.toggleReaction(message: withReaction, myUserId: 1, emoji: '❤️');
    expect(controller.state.messages.firstWhere((m) => m.id == 1).reactionBy(1), isNull);
    controller.dispose();
  });

  test('a socket reconnect after a drop refetches the thread', () async {
    socketStatus.value = SocketStatus.disconnected;
    final controller = build();
    await Future<void>.delayed(Duration.zero);
    clearInteractions(api);
    when(() => api.messages(any())).thenAnswer(
      (_) async => MessageHistoryPage(messages: [_message(1), _message(2)]),
    );

    socketStatus.value = SocketStatus.connected;
    await Future<void>.delayed(Duration.zero);

    verify(() => api.messages(any())).called(1);
    controller.dispose();
  });
}
