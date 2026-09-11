import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_states.dart';
import '../../shared/models/chat.dart';
import 'chats_controller.dart';

class ChatsScreen extends ConsumerWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatsControllerProvider);
    final controller = ref.read(chatsControllerProvider.notifier);

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: controller.load,
        color: MocoColors.accentPrimary,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                MocoSpacing.screenPadding,
                MocoSpacing.lg,
                MocoSpacing.screenPadding,
                MocoSpacing.md,
              ),
              child: Text(
                'Chats',
                style: TextStyle(
                  color: MocoColors.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(child: _Body(state: state, controller: controller)),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.controller});

  final ChatsState state;
  final ChatsController controller;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading && state.conversations.isEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.screenPadding),
        itemCount: 6,
        itemBuilder: (context, index) => const _RowSkeleton(),
      );
    }

    if (state.error != null && state.conversations.isEmpty) {
      return MocoErrorState(
        key: const Key('chats_error'),
        message: ApiErrorMapper.from(state.error!).message,
        onRetry: controller.load,
      );
    }

    if (state.isEmpty) {
      return const MocoEmptyState(
        key: Key('chats_empty'),
        title: 'No conversations yet',
        message: 'Messages with listeners you\'ve talked to will show up here.',
        icon: Icons.chat_bubble_outline_rounded,
      );
    }

    return ListView.separated(
      key: const Key('chats_list'),
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
      itemCount: state.conversations.length,
      separatorBuilder: (_, __) => const Divider(
        height: 1,
        indent: 84,
        color: MocoColors.borderSubtle,
      ),
      itemBuilder: (context, index) => _ConversationRow(
        conversation: state.conversations[index],
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('chat_row_${conversation.counterpartyId}'),
        onTap: () => context.push(
          Routes.chatThreadPath(conversation.counterpartyId),
          extra: conversation,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MocoSpacing.screenPadding,
            vertical: MocoSpacing.md,
          ),
          child: Row(
            children: [
              MocoAvatar(
                name: conversation.displayName,
                imageUrl: conversation.counterpartyAvatarUrl,
                size: 52,
              ),
              const SizedBox(width: MocoSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: MocoColors.textPrimary,
                              fontSize: 15.5,
                              fontWeight: conversation.hasUnread
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: MocoSpacing.sm),
                        Text(
                          formatRelativeTime(conversation.lastMessageAt),
                          style: const TextStyle(
                            color: MocoColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.lastMessage ?? 'Say hello',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: conversation.hasUnread
                                  ? MocoColors.textSecondary
                                  : MocoColors.textMuted,
                              fontSize: 13.5,
                              fontWeight: conversation.hasUnread
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (conversation.hasUnread) ...[
                          const SizedBox(width: MocoSpacing.sm),
                          _UnreadBadge(count: conversation.unreadCount),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('chat_unread_badge'),
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        gradient: MocoColors.accentGradient,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: MocoColors.textOnAccent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.md),
      child: Row(
        children: [
          const MocoSkeleton(width: 52, height: 52, radius: 26),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                MocoSkeleton(width: 120, height: 14),
                SizedBox(height: 8),
                MocoSkeleton(width: 180, height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
