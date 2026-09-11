import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/chat_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/chats/chats_screen.dart';
import 'package:moco/shared/models/chat.dart';

import '../support/harness.dart';

class _MockChatApi extends Mock implements ChatApi {}

const _conversation = Conversation(
  id: 1,
  counterpartyId: 7,
  counterpartyName: 'Priya',
  counterpartyAvatarUrl: null,
  lastMessage: 'See you soon!',
  unreadCount: 2,
);

void main() {
  late _MockChatApi api;
  late List<Override> base;

  setUp(() async {
    api = _MockChatApi();
    base = await baseOverrides();
  });

  Widget subject() => wrapShellScreen(
    const ChatsScreen(),
    overrides: [...base, chatApiProvider.overrideWithValue(api)],
  );

  testWidgets('shows an empty state when there are no conversations', (tester) async {
    when(() => api.conversations()).thenAnswer((_) async => []);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chats_empty')), findsOneWidget);
  });

  testWidgets('renders a conversation row with its unread badge', (tester) async {
    when(() => api.conversations()).thenAnswer((_) async => [_conversation]);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chats_list')), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
    expect(find.text('See you soon!'), findsOneWidget);
    expect(find.byKey(const Key('chat_unread_badge')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('shows a retryable error state when loading fails', (tester) async {
    when(() => api.conversations()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chats_error')), findsOneWidget);
  });
}
