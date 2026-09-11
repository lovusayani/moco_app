import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/chat_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/realtime/socket_service.dart';
import '../../core/utils/ws_events.dart';
import '../../shared/models/chat.dart';

class ChatsState {
  const ChatsState({
    this.conversations = const [],
    this.isLoading = true,
    this.error,
  });

  final List<Conversation> conversations;
  final bool isLoading;
  final ApiException? error;

  bool get isEmpty => !isLoading && error == null && conversations.isEmpty;

  ChatsState copyWith({
    List<Conversation>? conversations,
    bool? isLoading,
    ApiException? error,
    bool clearError = false,
  }) {
    return ChatsState(
      conversations: conversations ?? this.conversations,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the Chats list. Stays mounted underneath a pushed Chat Thread (the
/// thread route sits outside the shell, over this one — see app_router.dart),
/// so it keeps receiving `chat:message` live and the list is already current
/// by the time the user backs out of a thread.
class ChatsController extends StateNotifier<ChatsState> {
  ChatsController(this._api, this._socket) : super(const ChatsState()) {
    _messageOff = _socket?.on(WsEvents.chatMessage, _onIncoming);
    load();
  }

  final ChatApi _api;
  final SocketService? _socket;
  VoidCallback? _messageOff;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final conversations = await _api.conversations();
      state = state.copyWith(conversations: conversations, isLoading: false);
    } on ApiException catch (e) {
      state = state.copyWith(error: e, isLoading: false);
    }
  }

  void _onIncoming(dynamic data) {
    if (data is! Map) return;
    final event = ChatMessageEvent.fromJson(Map<String, dynamic>.from(data));
    final preview = event.type == MessageType.image ? 'Photo' : (event.body ?? '');

    final index = state.conversations.indexWhere(
      (c) => c.counterpartyId == event.senderId,
    );
    if (index < 0) {
      // A first message from someone with no existing row — refetch rather
      // than guess their name/avatar from the event alone.
      load();
      return;
    }

    final updated = [...state.conversations];
    final conv = updated.removeAt(index);
    updated.insert(
      0,
      conv.copyWith(
        lastMessage: preview,
        lastMessageAt: event.createdAt,
        unreadCount: conv.unreadCount + 1,
      ),
    );
    state = state.copyWith(conversations: updated);
  }

  /// Called by an open thread once it has fetched (and so server-marked-read)
  /// the latest messages for one conversation.
  void markRead(int counterpartyId) {
    final index = state.conversations.indexWhere(
      (c) => c.counterpartyId == counterpartyId,
    );
    if (index < 0 || state.conversations[index].unreadCount == 0) return;
    final updated = [...state.conversations];
    updated[index] = updated[index].copyWith(unreadCount: 0);
    state = state.copyWith(conversations: updated);
  }

  /// Called by a thread right after it successfully sends, so the list
  /// reflects the new last message without a full refetch.
  void bumpLastMessage({
    required int counterpartyId,
    required String preview,
    required DateTime at,
  }) {
    final index = state.conversations.indexWhere(
      (c) => c.counterpartyId == counterpartyId,
    );
    if (index < 0) return;
    final updated = [...state.conversations];
    final conv = updated.removeAt(index);
    updated.insert(0, conv.copyWith(lastMessage: preview, lastMessageAt: at));
    state = state.copyWith(conversations: updated);
  }

  @override
  void dispose() {
    _messageOff?.call();
    super.dispose();
  }
}

final chatsControllerProvider =
    StateNotifierProvider<ChatsController, ChatsState>((ref) {
      return ChatsController(
        ref.watch(chatApiProvider),
        ref.watch(socketServiceProvider),
      );
    });
