import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/safety_api.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/providers.dart';
import '../../../core/theme/moco_colors.dart';
import '../../../core/theme/moco_spacing.dart';
import '../../../shared/models/feed.dart';
import '../feed_controller.dart';

/// Report / block / delete for one post.
///
/// Report and block go to the existing `/api/safety` endpoints — the same
/// system discovery and chat already rely on. Nothing is filtered client-side:
/// a successful block simply means the server stops returning that user, and
/// the post is dropped from the local list so the change is visible now rather
/// than at the next refresh.
Future<void> showPostActionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required Post post,
  bool isOwnPost = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: MocoColors.backgroundElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(MocoRadius.xl)),
    ),
    builder: (sheetContext) => _PostActionsSheet(
      post: post,
      isOwnPost: isOwnPost,
      parentRef: ref,
    ),
  );
}

class _PostActionsSheet extends StatelessWidget {
  const _PostActionsSheet({
    required this.post,
    required this.isOwnPost,
    required this.parentRef,
  });

  final Post post;
  final bool isOwnPost;
  final WidgetRef parentRef;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: MocoSpacing.sm),
              decoration: BoxDecoration(
                color: MocoColors.borderStrong,
                borderRadius: BorderRadius.circular(MocoRadius.pill),
              ),
            ),
            if (isOwnPost)
              _Action(
                key: const Key('post_action_delete'),
                icon: Icons.delete_outline_rounded,
                label: 'Delete post',
                danger: true,
                onTap: () => _deletePost(context),
              )
            else ...[
              _Action(
                key: const Key('post_action_report'),
                icon: Icons.flag_outlined,
                label: 'Report post',
                onTap: () => _report(context),
              ),
              _Action(
                key: const Key('post_action_block'),
                icon: Icons.block_rounded,
                label: 'Block ${post.author.displayName}',
                danger: true,
                onTap: () => _block(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _deletePost(BuildContext context) async {
    // Capture the messenger BEFORE popping: afterwards this sheet's context is
    // defunct, and a toast looked up through it would silently never appear.
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    try {
      await parentRef.read(feedApiProvider).deletePost(post.id);
      parentRef.read(feedControllerProvider.notifier).removeLocally(post.id);
    } on ApiException catch (e) {
      _toast(messenger, ApiErrorMapper.from(e).message);
    }
  }

  Future<void> _block(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    try {
      await parentRef.read(safetyApiProvider).block(post.author.id);
      // The server will not return this author again; drop what is on screen
      // now so the block is visibly immediate.
      parentRef.read(feedControllerProvider.notifier).removeLocally(post.id);
      _toast(messenger, 'You will not see ${post.author.displayName} again.');
    } on ApiException catch (e) {
      _toast(messenger, ApiErrorMapper.from(e).message);
    }
  }

  Future<void> _report(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);

    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MocoColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(MocoRadius.xl)),
      ),
      builder: (reasonContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(MocoSpacing.lg),
                child: Text(
                  'Why are you reporting this?',
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final entry in SafetyApi.reportReasons.entries)
                _Action(
                  key: Key('report_reason_${entry.key}'),
                  icon: Icons.chevron_right_rounded,
                  label: entry.value,
                  onTap: () => Navigator.of(reasonContext).pop(entry.key),
                ),
            ],
          ),
        ),
      ),
    );

    if (navigator.canPop()) navigator.pop();
    if (reason == null) return;

    try {
      await parentRef
          .read(safetyApiProvider)
          .report(userId: post.author.id, reason: reason);
      _toast(messenger, 'Thanks — our team will review this.');
    } on ApiException catch (e) {
      _toast(messenger, ApiErrorMapper.from(e).message);
    }
  }

  void _toast(ScaffoldMessengerState? messenger, String message) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? MocoColors.danger : MocoColors.textPrimary;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}
