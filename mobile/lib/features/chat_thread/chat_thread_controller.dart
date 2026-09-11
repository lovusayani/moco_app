import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/chat_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/realtime/socket_service.dart';
import '../../core/utils/ws_events.dart';
import '../../shared/models/chat.dart';
import '../chats/chats_controller.dart';

class ThreadState {
  const ThreadState({
    this.messages = const [],
    this.isLoading = true,
    this.isLoadingOlder = false,
    this.hasMoreOlder = true,
    this.error,
    this.isSending = false,
    this.sendError,
    this.isUploadingPhoto = false,
  });

  /// Ascending by id — oldest first, matching how a thread reads top to bottom.
  final List<ChatMessage> messages;
  final bool isLoading;
  final bool isLoadingOlder;
  final bool hasMoreOlder;
  final ApiException? error;
  final bool isSending;
  final ApiException? sendError;
  final bool isUploadingPhoto;

  ThreadState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    bool? isLoadingOlder,
    bool? hasMoreOlder,
    ApiException? error,
    bool? isSending,
    ApiException? sendError,
    bool? isUploadingPhoto,
    bool clearError = false,
    bool clearSendError = false,
  }) {
    return ThreadState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
      error: clearError ? null : (error ?? this.error),
      isSending: isSending ?? this.isSending,
      sendError: clearSendError ? null : (sendError ?? this.sendError),
      isUploadingPhoto: isUploadingPhoto ?? this.isUploadingPhoto,
    );
  }
}

/// One controller per open thread (`.family` on the counterparty's id,
/// `autoDispose` so leaving the screen tears down its socket subscriptions —
/// see dispose()). [onRead]/[onSent] keep ChatsController's list in sync
/// without this controller depending on it directly.
class ChatThreadController extends StateNotifier<ThreadState> {
  ChatThreadController(
    this._api,
    this._socket,
    this.counterpartyId, {
    required this.onRead,
    required this.onSent,
  }) : super(const ThreadState()) {
    _messageOff = _socket?.on(WsEvents.chatMessage, _onIncomingMessage);
    _reactionOff = _socket?.on(WsEvents.chatReaction, _onIncomingReaction);
    // Seed from the current status, not null — otherwise the very first
    // connect-after-a-drop this controller observes is indistinguishable
    // from "no prior status" and the reconcile-on-reconnect never fires.
    _lastSocketStatus = _socket?.status.value;
    _socket?.status.addListener(_onSocketStatus);
    load();
  }

  final ChatApi _api;
  final SocketService? _socket;
  final int counterpartyId;
  final void Function(int counterpartyId) onRead;
  final void Function({
    required int counterpartyId,
    required String preview,
    required DateTime at,
  })
  onSent;

  VoidCallback? _messageOff;
  VoidCallback? _reactionOff;
  SocketStatus? _lastSocketStatus;

  static List<ChatMessage> _mergeById(
    List<ChatMessage> a,
    List<ChatMessage> b,
  ) {
    final map = {for (final m in a) m.id: m};
    for (final m in b) {
      map[m.id] = m;
    }
    final list = map.values.toList()..sort((x, y) => x.id.compareTo(y.id));
    return list;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final page = await _api.messages(counterpartyId);
      state = state.copyWith(
        messages: _mergeById(state.messages, page.messages),
        hasMoreOlder: page.hasMore,
        isLoading: false,
      );
      onRead(counterpartyId);
    } on ApiException catch (e) {
      state = state.copyWith(error: e, isLoading: false);
    }
  }

  /// Older history for infinite-scroll-up. Position is preserved by the
  /// screen (it keeps the scroll offset from the list's tail, not the head).
  Future<void> loadOlder() async {
    if (state.isLoadingOlder || !state.hasMoreOlder || state.messages.isEmpty) return;
    state = state.copyWith(isLoadingOlder: true);
    try {
      final oldestId = state.messages.first.id;
      final page = await _api.messages(counterpartyId, before: oldestId);
      state = state.copyWith(
        messages: _mergeById(page.messages, state.messages),
        hasMoreOlder: page.hasMore,
        isLoadingOlder: false,
      );
    } on ApiException {
      state = state.copyWith(isLoadingOlder: false);
    }
  }

  Future<void> sendText(String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty || state.isSending) return;

    state = state.copyWith(isSending: true, clearSendError: true);
    try {
      final message = await _api.sendText(counterpartyId, trimmed);
      state = state.copyWith(
        messages: _mergeById(state.messages, [message]),
        isSending: false,
      );
      onSent(counterpartyId: counterpartyId, preview: trimmed, at: message.createdAt);
    } on ApiException catch (e) {
      state = state.copyWith(isSending: false, sendError: e);
    }
  }

  /// Uploads [bytes] as a photo message: authorize -> PUT to Supabase Storage
  /// -> send the message referencing the resulting path. Any failure at any
  /// step surfaces through [ThreadState.sendError] — never a partially-sent,
  /// silently-retried message.
  Future<void> sendImage({required Uint8List bytes, required String mimeType}) async {
    if (state.isSending || state.isUploadingPhoto) return;

    state = state.copyWith(isUploadingPhoto: true, clearSendError: true);
    try {
      final auth = await _api.requestUploadUrl(mimeType);
      if (bytes.length > auth.maxBytes) {
        throw ApiException(
          kind: ApiErrorKind.validation,
          message: 'That photo is too large to send.',
        );
      }

      // Supabase Storage's signed-upload-URL protocol: PUT the raw bytes to
      // the signed URL, bearer-authorized with the one-time token it issued
      // (not this app's session token — a different, storage-scoped one).
      final uploadDio = Dio();
      await uploadDio.put<dynamic>(
        auth.uploadUrl,
        data: Stream.fromIterable([bytes]),
        options: Options(
          headers: {
            'Authorization': 'Bearer ${auth.token}',
            'Content-Type': mimeType,
            'x-upsert': 'false',
          },
          contentType: mimeType,
        ),
      );

      state = state.copyWith(isUploadingPhoto: false, isSending: true);
      final message = await _api.sendImage(counterpartyId, auth.path);
      state = state.copyWith(
        messages: _mergeById(state.messages, [message]),
        isSending: false,
      );
      onSent(counterpartyId: counterpartyId, preview: 'Photo', at: message.createdAt);
    } on ApiException catch (e) {
      state = state.copyWith(isUploadingPhoto: false, isSending: false, sendError: e);
    } catch (_) {
      state = state.copyWith(
        isUploadingPhoto: false,
        isSending: false,
        sendError: const ApiException(
          kind: ApiErrorKind.unknown,
          message: 'Could not send that photo. Please try again.',
        ),
      );
    }
  }

  /// Sets, changes, or (if [emoji] already matches this user's own reaction)
  /// removes the reaction — the approved design's single add/change/remove
  /// control. Optimistic, rolled back on failure.
  Future<void> toggleReaction({
    required ChatMessage message,
    required int myUserId,
    required String emoji,
  }) async {
    final mine = message.reactionBy(myUserId);
    final removing = mine?.emoji == emoji;

    final optimistic = message.withReaction(
      userId: myUserId,
      emoji: removing ? null : emoji,
    );
    state = state.copyWith(messages: _mergeById(state.messages, [optimistic]));

    try {
      if (removing) {
        await _api.removeReaction(message.id);
      } else {
        await _api.setReaction(message.id, emoji);
      }
    } on ApiException {
      state = state.copyWith(messages: _mergeById(state.messages, [message]));
    }
  }

  void _onIncomingMessage(dynamic data) {
    if (data is! Map) return;
    final event = ChatMessageEvent.fromJson(Map<String, dynamic>.from(data));
    if (event.senderId != counterpartyId) return;
    // Refetch rather than append the bare event: this also re-runs the
    // server-side mark-as-read for a thread that is actually open/visible.
    unawaited(_refetchRecent());
  }

  void _onIncomingReaction(dynamic data) {
    if (data is! Map) return;
    final event = ChatReactionEvent.fromJson(Map<String, dynamic>.from(data));
    final index = state.messages.indexWhere((m) => m.id == event.messageId);
    if (index < 0) return;
    final updated = [...state.messages];
    updated[index] = updated[index].withReaction(
      userId: event.userId,
      emoji: event.emoji,
    );
    state = state.copyWith(messages: updated);
  }

  /// A reconnect can have missed a message or reaction event outright — pull
  /// the latest page rather than trust the gap was empty.
  void _onSocketStatus() {
    final status = _socket?.status.value;
    final wasDown = _lastSocketStatus != null && _lastSocketStatus != SocketStatus.connected;
    _lastSocketStatus = status;
    if (wasDown && status == SocketStatus.connected) {
      unawaited(_refetchRecent());
    }
  }

  Future<void> _refetchRecent() async {
    try {
      final page = await _api.messages(counterpartyId);
      if (!mounted) return;
      state = state.copyWith(messages: _mergeById(state.messages, page.messages));
      onRead(counterpartyId);
    } on ApiException {
      // Next incoming event or reconnect tries again; nothing to show for this.
    }
  }

  @override
  void dispose() {
    _messageOff?.call();
    _reactionOff?.call();
    _socket?.status.removeListener(_onSocketStatus);
    super.dispose();
  }
}

final chatThreadControllerProvider = StateNotifierProvider.autoDispose
    .family<ChatThreadController, ThreadState, int>((ref, counterpartyId) {
      final chats = ref.watch(chatsControllerProvider.notifier);
      return ChatThreadController(
        ref.watch(chatApiProvider),
        ref.watch(socketServiceProvider),
        counterpartyId,
        onRead: chats.markRead,
        onSent: ({required counterpartyId, required preview, required at}) =>
            chats.bumpLastMessage(
              counterpartyId: counterpartyId,
              preview: preview,
              at: at,
            ),
      );
    });
