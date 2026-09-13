import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../core/widgets/moco_states.dart';
import '../../shared/models/notification.dart';
import 'notifications_controller.dart';

/// The Notifications inbox. Reached from a bell icon on Discovery — the five
/// bottom-nav tabs are fixed, so this is a pushed screen rather than a sixth
/// tab.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  void _openTarget(BuildContext context, AppNotification notification) {
    switch (notification.type) {
      case 'kyc_approved':
      case 'kyc_rejected':
        context.push(Routes.profile);
        break;
      case 'payout_approved':
      case 'payout_rejected':
      case 'payout_paid':
        context.push(Routes.earningsLedger);
        break;
      default:
        // An unrecognised type has nowhere honest to navigate — the
        // notification still opens (marked read) but stays where it is,
        // rather than guessing a route that might not exist.
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationsControllerProvider);
    final controller = ref.read(notificationsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Notifications'),
        actions: [
          if (state.unreadCount > 0)
            TextButton(
              key: const Key('notifications_mark_all_read'),
              onPressed: controller.markAllRead,
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: _Body(state: state, controller: controller, onTap: (n) => _openTarget(context, n)),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.controller, required this.onTap});

  final NotificationsState state;
  final NotificationsController controller;
  final void Function(AppNotification) onTap;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading && state.notifications.isEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.all(MocoSpacing.screenPadding),
        itemCount: 6,
        itemBuilder: (context, index) => const Padding(
          padding: EdgeInsets.only(bottom: MocoSpacing.md),
          child: MocoSkeleton(height: 64),
        ),
      );
    }

    if (state.isFatalError) {
      return MocoErrorState(
        key: const Key('notifications_error'),
        message: ApiErrorMapper.from(state.error!).message,
        onRetry: controller.load,
      );
    }

    if (state.isEmpty) {
      return const MocoEmptyState(
        key: Key('notifications_empty'),
        title: 'No notifications yet',
        message: 'Updates about your account will show up here.',
        icon: Icons.notifications_none_rounded,
      );
    }

    return RefreshIndicator(
      onRefresh: controller.load,
      color: MocoColors.accentPrimary,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels > notification.metrics.maxScrollExtent - 200) {
            controller.loadMore();
          }
          return false;
        },
        child: ListView.separated(
          key: const Key('notifications_list'),
          padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
          itemCount: state.notifications.length + (state.hasMore ? 1 : 0),
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 68, color: MocoColors.borderSubtle),
          itemBuilder: (context, index) {
            if (index >= state.notifications.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: MocoSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final notification = state.notifications[index];
            return Dismissible(
              key: ValueKey('notification_${notification.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: MocoColors.danger.withValues(alpha: 0.2),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg),
                child: const Icon(Icons.delete_outline_rounded, color: MocoColors.danger),
              ),
              onDismissed: (_) => controller.delete(notification.id),
              child: _NotificationRow(
                notification: notification,
                onTap: () {
                  controller.markRead(notification.id);
                  onTap(notification);
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  IconData get _icon => switch (notification.type) {
    'kyc_approved' => Icons.verified_rounded,
    'kyc_rejected' => Icons.error_outline_rounded,
    'payout_approved' => Icons.check_circle_outline_rounded,
    'payout_rejected' => Icons.cancel_outlined,
    'payout_paid' => Icons.account_balance_wallet_outlined,
    _ => Icons.notifications_none_rounded,
  };

  Color get _iconColor => switch (notification.type) {
    'kyc_approved' || 'payout_approved' || 'payout_paid' => MocoColors.online,
    'kyc_rejected' || 'payout_rejected' => MocoColors.danger,
    _ => MocoColors.accentSoft,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: notification.read ? Colors.transparent : MocoColors.surfaceGlass,
      child: InkWell(
        key: Key('notification_row_${notification.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MocoSpacing.screenPadding,
            vertical: MocoSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: MocoColors.surfaceGlass,
                  shape: BoxShape.circle,
                ),
                child: Icon(_icon, color: _iconColor, size: 20),
              ),
              const SizedBox(width: MocoSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification.title,
                      style: TextStyle(
                        color: MocoColors.textPrimary,
                        fontSize: 14.5,
                        fontWeight: notification.read ? FontWeight.w500 : FontWeight.w700,
                      ),
                    ),
                    if (notification.body != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        notification.body!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: MocoColors.textSecondary, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      formatRelativeTime(notification.createdAt),
                      style: const TextStyle(color: MocoColors.textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (!notification.read)
                Container(
                  key: const Key('notification_unread_dot'),
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: const BoxDecoration(
                    color: MocoColors.accentPrimary,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
