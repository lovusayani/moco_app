import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/friends_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/routing/app_router.dart';
import '../../core/routing/pop_or_go.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import 'friend_requests_controller.dart';

/// Pending friend requests the signed-in user has received.
class FriendRequestsScreen extends ConsumerWidget {
  const FriendRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(friendRequestsControllerProvider);
    final controller = ref.read(friendRequestsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Friend requests'),
        leading: deepLinkBackButton(context, Routes.profile),
      ),
      body: _Body(state: state, controller: controller),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.controller});

  final FriendRequestsState state;
  final FriendRequestsController controller;

  Future<void> _respond(BuildContext context, int requestId, {required bool accept}) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await controller.respond(requestId, accept: accept);
    if (outcome.kind == RespondOutcomeKind.ignored) return;
    messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
  }

  @override
  Widget build(BuildContext context) {
    if (state.isLoading && state.requests.isEmpty) {
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
        key: const Key('friend_requests_error'),
        message: ApiErrorMapper.from(state.error!).message,
        onRetry: controller.load,
      );
    }

    if (state.isEmpty) {
      return const MocoEmptyState(
        key: Key('friend_requests_empty'),
        title: 'No pending friend requests',
        message: 'New requests will show up here.',
        icon: Icons.person_add_alt_1_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: controller.load,
      color: MocoColors.accentPrimary,
      child: ListView.separated(
        key: const Key('friend_requests_list'),
        padding: const EdgeInsets.symmetric(
          horizontal: MocoSpacing.screenPadding,
          vertical: MocoSpacing.md,
        ),
        itemCount: state.requests.length,
        separatorBuilder: (_, __) => const SizedBox(height: MocoSpacing.sm),
        itemBuilder: (context, index) {
          final request = state.requests[index];
          return _RequestRow(
            request: request,
            busy: state.busyIds.contains(request.requestId),
            onAccept: () => _respond(context, request.requestId, accept: true),
            onReject: () => _respond(context, request.requestId, accept: false),
          );
        },
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.request,
    required this.busy,
    required this.onAccept,
    required this.onReject,
  });

  final PendingFriendRequest request;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final id = request.requestId;
    return Container(
      key: Key('friend_request_row_$id'),
      padding: const EdgeInsets.all(MocoSpacing.md),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.md),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MocoAvatar(
                name: request.requesterName,
                imageUrl: request.requesterAvatarUrl,
                size: 44,
              ),
              const SizedBox(width: MocoSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.requesterName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MocoColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatRelativeTime(DateTime.tryParse(request.createdAt)),
                      style: TextStyle(color: MocoColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: MocoSpacing.md),
          Row(
            children: [
              Expanded(
                child: MocoPrimaryButton(
                  key: Key('friend_request_accept_$id'),
                  label: 'Accept',
                  loading: busy,
                  onPressed: busy ? null : onAccept,
                ),
              ),
              const SizedBox(width: MocoSpacing.sm),
              Expanded(
                child: MocoSecondaryButton(
                  key: Key('friend_request_reject_$id'),
                  label: 'Reject',
                  onPressed: busy ? null : onReject,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
