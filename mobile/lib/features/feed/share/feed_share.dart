import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/routing/app_router.dart';
import '../../../shared/models/feed.dart';
import '../feed_controller.dart';
import 'native_share.dart';

typedef NativeShareLauncher = Future<NativeShareOutcome> Function({
  required String title,
  required String text,
  required String url,
});

/// The system share sheet. Injected so tests can stand in for the browser.
final nativeShareProvider = Provider<NativeShareLauncher>(
  (ref) => shareNatively,
);

/// The link that opens [post] in the Feed.
String feedPostLink(Post post) =>
    '${Env.webAppUrl}${Routes.feedPostPath(post.id)}';

/// Shares [post]: the system share sheet where there is one, otherwise the
/// link is copied. Only a completed share or a successful copy is recorded —
/// a cancelled sheet, a failed copy, or simply showing the post never is.
Future<void> shareFeedPost({
  required BuildContext context,
  required WidgetRef ref,
  required Post post,
}) async {
  final url = feedPostLink(post);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final controller = ref.read(feedControllerProvider.notifier);
  final caption = post.caption?.trim();

  final outcome = await ref.read(nativeShareProvider)(
    title: 'Moco',
    text: (caption?.isNotEmpty ?? false)
        ? caption!
        : '${post.author.displayName} on Moco',
    url: url,
  );

  switch (outcome) {
    case NativeShareOutcome.shared:
      await controller.recordShare(post.id, method: 'native');
    case NativeShareOutcome.cancelled:
      return;
    case NativeShareOutcome.unavailable:
      try {
        await Clipboard.setData(ClipboardData(text: url));
      } catch (_) {
        messenger?.showSnackBar(
          const SnackBar(
            key: Key('feed_share_copy_failed'),
            content: Text('Could not copy the link'),
          ),
        );
        return;
      }
      messenger?.showSnackBar(
        const SnackBar(
          key: Key('feed_share_copied'),
          content: Text('Link copied'),
          duration: Duration(seconds: 2),
        ),
      );
      await controller.recordShare(post.id, method: 'copy');
  }
}
