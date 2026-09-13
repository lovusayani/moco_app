import 'dart:typed_data';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';
import '../../shared/models/chat.dart';
import '../safety/safety_actions_sheet.dart';
import 'chat_thread_controller.dart';

const _quickReactions = ['❤️', '😂', '👍', '😮', '😢', '🙏'];

class ChatThreadScreen extends ConsumerStatefulWidget {
  const ChatThreadScreen({
    super.key,
    required this.counterpartyId,
    this.counterpartyName,
    this.counterpartyAvatarUrl,
  });

  final int counterpartyId;
  final String? counterpartyName;
  final String? counterpartyAvatarUrl;

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  final _picker = ImagePicker();
  bool _composerHasText = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _textController.addListener(() {
      final hasText = _textController.text.trim().isNotEmpty;
      if (hasText != _composerHasText) setState(() => _composerHasText = hasText);
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels <= 200) {
      _loadOlderPreservingPosition();
    }
  }

  Future<void> _loadOlderPreservingPosition() async {
    final controller = ref.read(
      chatThreadControllerProvider(widget.counterpartyId).notifier,
    );
    final before = _scrollController.position.maxScrollExtent;
    await controller.loadOlder();
    if (!mounted || !_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final after = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(_scrollController.offset + (after - before));
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _textController.text;
    if (text.trim().isEmpty) return;
    _textController.clear();
    setState(() => _composerHasText = false);
    await ref
        .read(chatThreadControllerProvider(widget.counterpartyId).notifier)
        .sendText(text);
    _scrollToBottom();
  }

  Future<void> _pickAndSendPhoto() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    final mimeType = switch (picked.name.toLowerCase()) {
      final n when n.endsWith('.png') => 'image/png',
      final n when n.endsWith('.webp') => 'image/webp',
      _ => 'image/jpeg',
    };

    await ref
        .read(chatThreadControllerProvider(widget.counterpartyId).notifier)
        .sendImage(bytes: Uint8List.fromList(bytes), mimeType: mimeType);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatThreadControllerProvider(widget.counterpartyId));
    final myUserId = ref.watch(authControllerProvider).user?.id;

    ref.listen(chatThreadControllerProvider(widget.counterpartyId), (previous, next) {
      final grew = (previous?.messages.length ?? 0) < next.messages.length;
      final wasNearBottom =
          !_scrollController.hasClients ||
          _scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 120;
      if (grew && wasNearBottom) _scrollToBottom();
    });

    return Scaffold(
      body: MocoBackground(
        ambience: MocoAmbience.standard,
        child: SafeArea(
          child: Column(
            children: [
              _ThreadHeader(
                counterpartyId: widget.counterpartyId,
                name: widget.counterpartyName ?? 'Chat',
                avatarUrl: widget.counterpartyAvatarUrl,
              ),
              Expanded(
                child: _Body(
                  state: state,
                  scrollController: _scrollController,
                  myUserId: myUserId,
                  counterpartyId: widget.counterpartyId,
                ),
              ),
              _Composer(
                textController: _textController,
                hasText: _composerHasText,
                isSending: state.isSending,
                isUploadingPhoto: state.isUploadingPhoto,
                onSend: _send,
                onAttachPhoto: _pickAndSendPhoto,
              ),
              if (state.sendError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MocoSpacing.lg,
                    0,
                    MocoSpacing.lg,
                    MocoSpacing.sm,
                  ),
                  child: Text(
                    ApiErrorMapper.from(state.sendError!).message,
                    style: const TextStyle(color: MocoColors.danger, fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThreadHeader extends ConsumerWidget {
  const _ThreadHeader({required this.counterpartyId, required this.name, this.avatarUrl});

  final int counterpartyId;
  final String name;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MocoSpacing.sm,
            vertical: MocoSpacing.sm,
          ),
          decoration: const BoxDecoration(
            color: Color(0x22140A14),
            border: Border(bottom: BorderSide(color: MocoColors.borderSubtle)),
          ),
          child: Row(
            children: [
              IconButton(
                key: const Key('chat_thread_back'),
                icon: const Icon(Icons.arrow_back_rounded, color: MocoColors.textPrimary),
                onPressed: () => context.pop(),
              ),
              MocoAvatar(name: name, imageUrl: avatarUrl, size: 38),
              const SizedBox(width: MocoSpacing.sm),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                key: const Key('chat_thread_more'),
                icon: const Icon(Icons.more_vert_rounded, color: MocoColors.textPrimary),
                tooltip: 'Report or block',
                onPressed: () => showSafetyActionsSheet(
                  context: context,
                  ref: ref,
                  userId: counterpartyId,
                  userName: name,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.state,
    required this.scrollController,
    required this.myUserId,
    required this.counterpartyId,
  });

  final ThreadState state;
  final ScrollController scrollController;
  final int? myUserId;
  final int counterpartyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isLoading && state.messages.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }

    if (state.error != null && state.messages.isEmpty) {
      return MocoErrorState(
        key: const Key('chat_thread_error'),
        message: ApiErrorMapper.from(state.error!).message,
        onRetry: () =>
            ref.read(chatThreadControllerProvider(counterpartyId).notifier).load(),
      );
    }

    if (state.messages.isEmpty) {
      return const MocoEmptyState(
        key: Key('chat_thread_empty'),
        title: 'Say hello',
        message: 'No messages yet — send the first one.',
        icon: Icons.waving_hand_rounded,
      );
    }

    final groups = _groupByDay(state.messages);

    return ListView.builder(
      key: const Key('chat_thread_list'),
      controller: scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.screenPadding,
        vertical: MocoSpacing.md,
      ),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.md, vertical: 4),
                  decoration: BoxDecoration(
                    color: MocoColors.surfaceGlass,
                    borderRadius: BorderRadius.circular(MocoRadius.pill),
                  ),
                  child: Text(
                    formatDateSeparator(group.day),
                    style: const TextStyle(color: MocoColors.textMuted, fontSize: 11.5),
                  ),
                ),
              ),
            ),
            for (final message in group.messages)
              _MessageBubble(
                key: ValueKey(message.id),
                message: message,
                isMine: myUserId != null && message.isSentBy(myUserId!),
                myUserId: myUserId,
                counterpartyId: counterpartyId,
              ),
          ],
        );
      },
    );
  }

  List<_DayGroup> _groupByDay(List<ChatMessage> messages) {
    final groups = <_DayGroup>[];
    for (final message in messages) {
      if (groups.isNotEmpty && isSameDay(groups.last.day, message.createdAt)) {
        groups.last.messages.add(message);
      } else {
        groups.add(_DayGroup(day: message.createdAt, messages: [message]));
      }
    }
    return groups;
  }
}

class _DayGroup {
  _DayGroup({required this.day, required this.messages});
  final DateTime day;
  final List<ChatMessage> messages;
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.myUserId,
    required this.counterpartyId,
  });

  final ChatMessage message;
  final bool isMine;
  final int? myUserId;
  final int counterpartyId;

  void _showReactionPicker(BuildContext context, WidgetRef ref) {
    if (myUserId == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(MocoSpacing.lg),
        padding: const EdgeInsets.symmetric(vertical: MocoSpacing.md),
        decoration: BoxDecoration(
          color: MocoColors.backgroundElevated,
          borderRadius: BorderRadius.circular(MocoRadius.lg),
          border: Border.all(color: MocoColors.borderSubtle),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          children: [
            for (final emoji in _quickReactions)
              IconButton(
                key: Key('reaction_option_$emoji'),
                onPressed: () {
                  Navigator.of(context).pop();
                  ref
                      .read(chatThreadControllerProvider(counterpartyId).notifier)
                      .toggleReaction(message: message, myUserId: myUserId!, emoji: emoji);
                },
                icon: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final align = isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isMine ? null : MocoColors.surfaceGlass;

    return Padding(
      padding: const EdgeInsets.only(bottom: MocoSpacing.sm),
      child: Column(
        crossAxisAlignment: align,
        children: [
          GestureDetector(
            onLongPress: () => _showReactionPicker(context, ref),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              child: Container(
                padding: message.isImage
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(
                        horizontal: MocoSpacing.md,
                        vertical: MocoSpacing.sm,
                      ),
                decoration: BoxDecoration(
                  gradient: isMine ? MocoColors.accentGradient : null,
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(MocoRadius.md),
                    topRight: const Radius.circular(MocoRadius.md),
                    bottomLeft: Radius.circular(isMine ? MocoRadius.md : 4),
                    bottomRight: Radius.circular(isMine ? 4 : MocoRadius.md),
                  ),
                  border: isMine ? null : Border.all(color: MocoColors.borderSubtle),
                ),
                child: message.isImage
                    ? _ImageContent(message: message)
                    : Text(
                        message.body ?? '',
                        style: TextStyle(
                          color: isMine ? MocoColors.textOnAccent : MocoColors.textPrimary,
                          fontSize: 14.5,
                          height: 1.35,
                        ),
                      ),
              ),
            ),
          ),
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 2,
                children: [
                  for (final r in message.reactions)
                    Text(r.emoji, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              formatClockTime(message.createdAt),
              style: const TextStyle(color: MocoColors.textMuted, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageContent extends StatelessWidget {
  const _ImageContent({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final url = message.mediaUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MocoRadius.sm),
      child: url == null
          ? Container(
              width: 200,
              height: 200,
              color: MocoColors.surfaceGlassStrong,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image_outlined, color: MocoColors.textMuted),
            )
          : CachedNetworkImage(
              imageUrl: url,
              width: 220,
              fit: BoxFit.cover,
              placeholder: (_, __) => const SizedBox(
                width: 220,
                height: 220,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (_, __, ___) => Container(
                width: 220,
                height: 220,
                color: MocoColors.surfaceGlassStrong,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined, color: MocoColors.textMuted),
              ),
            ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.textController,
    required this.hasText,
    required this.isSending,
    required this.isUploadingPhoto,
    required this.onSend,
    required this.onAttachPhoto,
  });

  final TextEditingController textController;
  final bool hasText;
  final bool isSending;
  final bool isUploadingPhoto;
  final VoidCallback onSend;
  final VoidCallback onAttachPhoto;

  @override
  Widget build(BuildContext context) {
    final busy = isSending || isUploadingPhoto;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        MocoSpacing.md,
        MocoSpacing.sm,
        MocoSpacing.md,
        MediaQuery.of(context).viewInsets.bottom > 0
            ? MocoSpacing.sm
            : MocoSpacing.sm + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            key: const Key('chat_attach_photo'),
            onPressed: busy ? null : onAttachPhoto,
            icon: isUploadingPhoto
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.image_outlined, color: MocoColors.textSecondary),
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.md),
              decoration: BoxDecoration(
                color: MocoColors.surfaceGlass,
                borderRadius: BorderRadius.circular(MocoRadius.lg),
                border: Border.all(color: MocoColors.borderSubtle),
              ),
              child: TextField(
                key: const Key('chat_composer_input'),
                controller: textController,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: MocoColors.textPrimary, fontSize: 14.5),
                decoration: const InputDecoration(
                  hintText: 'Message',
                  hintStyle: TextStyle(color: MocoColors.textMuted),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: MocoSpacing.sm),
          SizedBox(
            width: 44,
            height: 44,
            child: Material(
              color: Colors.transparent,
              child: Ink(
                decoration: BoxDecoration(
                  gradient: (hasText && !busy) ? MocoColors.accentGradient : null,
                  color: (hasText && !busy) ? null : MocoColors.surfaceGlass,
                  shape: BoxShape.circle,
                ),
                child: InkWell(
                  key: const Key('chat_send_button'),
                  customBorder: const CircleBorder(),
                  onTap: (hasText && !busy) ? onSend : null,
                  child: isSending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(MocoColors.textOnAccent),
                          ),
                        )
                      : Icon(
                          Icons.arrow_upward_rounded,
                          color: hasText ? MocoColors.textOnAccent : MocoColors.textMuted,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
