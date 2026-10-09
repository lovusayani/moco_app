import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/providers.dart';
import '../../../core/theme/moco_colors.dart';
import '../../../core/theme/moco_spacing.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/moco_avatar.dart';
import '../../../shared/models/feed.dart';

/// The comments for one post, as a glass bottom sheet over the Feed.
///
/// [onCountChanged] receives the server's total after every add or delete,
/// so the Feed's comment counter is the server's number, not a local guess.
Future<void> showCommentsSheet({
  required BuildContext context,
  required Post post,
  required ValueChanged<int> onCountChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Above AppShell's floating nav bar, like the post actions sheet.
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (_) => CommentsSheet(post: post, onCountChanged: onCountChanged),
  );
}

class CommentsSheet extends ConsumerStatefulWidget {
  const CommentsSheet({
    super.key,
    required this.post,
    required this.onCountChanged,
  });

  final Post post;
  final ValueChanged<int> onCountChanged;

  @override
  ConsumerState<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<CommentsSheet> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<PostComment> _comments = const [];
  int? _nextCursor;
  late int _count = widget.post.commentCount;
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;
  ApiException? _error;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    _scroll.addListener(_maybeLoadMore);
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(feedApiProvider).comments(widget.post.id);
      if (!mounted) return;
      setState(() {
        _comments = page.comments;
        _nextCursor = page.nextCursor;
        _loading = false;
      });
      _setCount(page.commentCount);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _maybeLoadMore() async {
    if (_loadingMore || _nextCursor == null) return;
    if (_scroll.position.extentAfter > 200) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(feedApiProvider)
          .comments(widget.post.id, cursor: _nextCursor);
      if (!mounted) return;
      final have = _comments.map((c) => c.id).toSet();
      setState(() {
        _comments = [
          ..._comments,
          ...page.comments.where((c) => !have.contains(c.id)),
        ];
        _nextCursor = page.nextCursor;
      });
    } on ApiException {
      // Keep what is shown; scrolling again retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _setCount(int count) {
    _count = count;
    widget.onCountChanged(count);
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final added = await ref
          .read(feedApiProvider)
          .addComment(widget.post.id, body);
      if (!mounted) return;
      _input.clear();
      setState(() => _comments = [added.comment, ..._comments]);
      _setCount(added.commentCount);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } on ApiException catch (e) {
      _toast(ApiErrorMapper.from(e).message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(PostComment comment) async {
    // An in-app confirmation — never a browser dialog.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MocoColors.backgroundElevated,
        title: const Text('Delete comment?'),
        content: const Text('This removes it for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('feed_comment_delete_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: MocoColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final count = await ref
          .read(feedApiProvider)
          .deleteComment(widget.post.id, comment.id);
      if (!mounted) return;
      setState(
        () => _comments = _comments.where((c) => c.id != comment.id).toList(),
      );
      _setCount(count);
    } on ApiException catch (e) {
      _toast(ApiErrorMapper.from(e).message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = media.size.height * 0.68;

    return Padding(
      // Rides above the on-screen keyboard.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MocoRadius.xl),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            key: const Key('feed_comments_sheet'),
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  MocoColors.backgroundElevated.withValues(alpha: 0.86),
                  MocoColors.backgroundPrimary.withValues(alpha: 0.94),
                ],
              ),
              border: Border(
                top: BorderSide(
                  color: MocoColors.accentPrimary.withValues(alpha: 0.35),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  _header(),
                  Divider(height: 1, color: MocoColors.borderSubtle),
                  Expanded(child: _list()),
                  _composer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MocoSpacing.screenPadding,
        MocoSpacing.sm,
        MocoSpacing.sm,
        MocoSpacing.xs,
      ),
      child: Column(
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
          Row(
            children: [
              Text(
                'Comments',
                style: TextStyle(
                  color: MocoColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: MocoSpacing.sm),
              Text(
                '$_count',
                key: const Key('feed_comments_sheet_count'),
                style: TextStyle(color: MocoColors.textSecondary, fontSize: 14),
              ),
              const Spacer(),
              IconButton(
                key: const Key('feed_comments_close'),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(
                  Icons.close_rounded,
                  color: MocoColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: MocoColors.accentSoft,
          ),
        ),
      );
    }
    if (_error != null && _comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ApiErrorMapper.from(_error!).message,
              style: TextStyle(color: MocoColors.textSecondary),
            ),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return Center(
        key: const Key('feed_comments_empty'),
        child: Text(
          'No comments yet. Start the conversation.',
          style: TextStyle(color: MocoColors.textSecondary, fontSize: 13.5),
        ),
      );
    }
    return ListView.builder(
      key: const Key('feed_comments_list'),
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
      itemCount: _comments.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _comments.length) {
          return const Padding(
            padding: EdgeInsets.all(MocoSpacing.md),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final comment = _comments[index];
        return _CommentRow(
          comment: comment,
          onDelete: comment.canDelete ? () => _delete(comment) : null,
        );
      },
    );
  }

  Widget _composer() {
    final canSend = _input.text.trim().isNotEmpty && !_sending;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        MocoSpacing.lg,
        MocoSpacing.sm,
        MocoSpacing.sm,
        MocoSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: MocoColors.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('feed_comment_input'),
              controller: _input,
              minLines: 1,
              maxLines: 4,
              maxLength: 500,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: TextStyle(color: MocoColors.textPrimary, fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Add a comment…',
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: MocoColors.surfaceGlass,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: MocoSpacing.lg,
                  vertical: MocoSpacing.md,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MocoRadius.lg),
                  borderSide: BorderSide(color: MocoColors.borderSubtle),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MocoRadius.lg),
                  borderSide: BorderSide(color: MocoColors.borderSubtle),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MocoRadius.lg),
                  borderSide: BorderSide(
                    color: MocoColors.accentPrimary.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: MocoSpacing.sm),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: canSend ? 1 : 0.45,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('feed_comment_send'),
                onTap: canSend ? _send : null,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: MocoColors.accentGradient,
                  ),
                  child: _sending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          size: 20,
                          color: Colors.white,
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

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment, this.onDelete});

  final PostComment comment;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('feed_comment_${comment.id}'),
      padding: const EdgeInsets.fromLTRB(
        MocoSpacing.screenPadding,
        MocoSpacing.sm,
        MocoSpacing.xs,
        MocoSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MocoAvatar(
            name: comment.authorDisplayName,
            imageUrl: comment.authorAvatarUrl,
            size: 34,
          ),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.authorDisplayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MocoColors.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: MocoSpacing.sm),
                    Text(
                      formatRelativeTime(comment.createdAt),
                      style: TextStyle(
                        color: MocoColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  comment.body,
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              key: Key('feed_comment_delete_${comment.id}'),
              tooltip: 'Delete comment',
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 19,
                color: MocoColors.textMuted,
              ),
            )
          else
            const SizedBox(width: MocoSpacing.lg),
        ],
      ),
    );
  }
}
