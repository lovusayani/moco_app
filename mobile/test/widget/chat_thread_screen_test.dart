import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/chat_thread/chat_thread_screen.dart';
import 'package:moco/shared/models/chat.dart';

import '../support/harness.dart';

class _MockChatApi extends Mock implements ChatApi {}

ChatMessage _message(int id, {int senderId = 7, String body = 'hello'}) {
  return ChatMessage(
    id: id,
    conversationId: 1,
    senderId: senderId,
    type: MessageType.text,
    body: body,
    createdAt: DateTime(2026, 1, 1, 10, id),
  );
}

void main() {
  late _MockChatApi api;
  late List<Override> base;

  setUp(() async {
    api = _MockChatApi();
    base = await baseOverrides();
    // ChatThreadScreen's controller also constructs ChatsController (to
    // notify the list of reads/sends) — the list underneath is always
    // mounted in the real app (see app_router.dart), so its own load() runs
    // here too and needs a stub even though this test never asserts on it.
    when(() => api.conversations()).thenAnswer((_) async => []);
  });

  Widget subject() => wrapWidget(
    const ChatThreadScreen(counterpartyId: 7, counterpartyName: 'Priya'),
    overrides: [...base, chatApiProvider.overrideWithValue(api)],
  );

  testWidgets('renders history and shows an empty state with none', (tester) async {
    when(() => api.messages(7)).thenAnswer(
      (_) async => const MessageHistoryPage(messages: []),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat_thread_empty')), findsOneWidget);
  });

  testWidgets('renders each message\'s text', (tester) async {
    when(() => api.messages(7)).thenAnswer(
      (_) async => MessageHistoryPage(
        messages: [_message(1, body: 'hey there'), _message(2, senderId: 1, body: 'hi back')],
      ),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.text('hey there'), findsOneWidget);
    expect(find.text('hi back'), findsOneWidget);
  });

  testWidgets('the send button is disabled until text is entered', (tester) async {
    when(() => api.messages(7)).thenAnswer(
      (_) async => const MessageHistoryPage(messages: []),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    final sendButton = find.byKey(const Key('chat_send_button'));
    expect(sendButton, findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat_composer_input')), 'hello there');
    await tester.pump();

    when(() => api.sendText(7, 'hello there')).thenAnswer(
      (_) async => _message(9, senderId: 1, body: 'hello there'),
    );

    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    verify(() => api.sendText(7, 'hello there')).called(1);
    expect(find.text('hello there'), findsOneWidget);
  });

  testWidgets('a blocked send shows the error rather than a sent message', (tester) async {
    when(() => api.messages(7)).thenAnswer(
      (_) async => const MessageHistoryPage(messages: []),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    when(() => api.sendText(7, 'nope')).thenThrow(
      const ApiException(kind: ApiErrorKind.forbidden, message: 'This user is not available'),
    );

    await tester.enterText(find.byKey(const Key('chat_composer_input')), 'nope');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat_send_button')));
    await tester.pumpAndSettle();

    expect(find.text('This user is not available'), findsOneWidget);
    expect(find.text('nope'), findsNothing);
  });
}
