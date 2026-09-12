import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';
import '../../../core/theme/moco_spacing.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/moco_avatar.dart';
import '../../../shared/models/feed.dart';
import 'feed_video.dart';

/// One full-screen feed page: the media, and the author/caption overlay on top.
class FeedPostItem extends StatelessWidget {
  const FeedPostItem({
    super.key,
    required this.post,
    required this.isActive,
    this.onAuthorTap,
    this.onMoreTap,
  });

  final Post post;

  /// True only for the feed's current page while the app is in the foreground.
  /// Passed straight through to [FeedVideo], which is what makes "only the
  /// visible video plays" a single rule in a single place.
  final bool isActive;

  /// Null when the author has no profile screen to open — see
  /// [PostAuthor.isListener]. The name then renders as plain text rather than
  /// as a control that goes nowhere.
  final VoidCallback? onAuthorTap;
  final VoidCallback? onMoreTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _Media(post: post, isActive: isActive),
        // Scrim behind the overlay text. Without it, white text over a bright
        // photo is unreadable — and the feed cannot choose its own photos.
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 320,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xCC000000)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _Overlay(
            post: post,
            onAuthorTap: onAuthorTap,
            onMoreTap: onMoreTap,
          ),
        ),
      ],
    );
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.post, required this.isActive});

  final Post post;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    if (!post.hasMedia) {
      return const _MediaUnavailable(key: Key('feed_media_missing'));
    }

    if (post.isVideo) {
      return FeedVideo(
        key: ValueKey('feed_video_${post.id}'),
        url: post.mediaUrl!,
        isActive: isActive,
      );
    }

    // Decode to the screen's pixel size rather than the source's. A 4000px
    // photo decoded at full size is ~64MB of bitmap; at device width it is a
    // fraction of that, and the feed holds several at once.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);

    return CachedNetworkImage(
      key: ValueKey('feed_image_${post.id}'),
      imageUrl: post.mediaUrl!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      memCacheWidth: (size.width * dpr).round(),
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (_, __) => const ColoredBox(
        color: MocoColors.backgroundPrimary,
        child: Center(
          child: SizedBox(
            key: Key('feed_image_loading'),
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: MocoColors.accentSoft,
            ),
          ),
        ),
      ),
      errorWidget: (_, __, ___) =>
          const _MediaUnavailable(key: Key('feed_image_error')),
    );
  }
}

/// Shown when media cannot be displayed — a signed URL the server could not
/// mint, or one that failed to load. The post still renders with its author
/// and caption rather than vanishing, so the feed degrades instead of lying.
class _MediaUnavailable extends StatelessWidget {
  const _MediaUnavailable({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: MocoColors.backgroundPrimary,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 44,
              color: MocoColors.textMuted,
            ),
            SizedBox(height: MocoSpacing.md),
            Text(
              'Media unavailable',
              style: TextStyle(color: MocoColors.textMuted, fontSize: 13.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay({required this.post, this.onAuthorTap, this.onMoreTap});

  final Post post;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onMoreTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Clears the bottom navigation bar, which the shell draws over the body.
      padding: const EdgeInsets.fromLTRB(
        MocoSpacing.screenPadding,
        MocoSpacing.lg,
        MocoSpacing.screenPadding,
        96,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: _AuthorRow(post: post, onTap: onAuthorTap),
              ),
              const SizedBox(width: MocoSpacing.sm),
              if (onMoreTap != null)
                IconButton(
                  key: const Key('feed_post_more'),
                  onPressed: onMoreTap,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: MocoColors.textPrimary,
                  ),
                  tooltip: 'Report or block',
                ),
            ],
          ),
          if (post.hasCaption) ...[
            const SizedBox(height: MocoSpacing.md),
            Text(
              post.caption!,
              key: const Key('feed_post_caption'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 14.5,
                height: 1.4,
                shadows: [
                  Shadow(color: Color(0x99000000), blurRadius: 8),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuthorRow extends StatelessWidget {
  const _AuthorRow({required this.post, this.onTap});

  final Post post;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final author = post.author;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MocoAvatar(
          name: author.displayName,
          imageUrl: author.avatarUrl,
          size: 42,
          ring: author.isListener,
        ),
        const SizedBox(width: MocoSpacing.md),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      author.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: MocoColors.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          Shadow(color: Color(0x99000000), blurRadius: 8),
                        ],
                      ),
                    ),
                  ),
                  if (author.verified) ...[
                    const SizedBox(width: 4),
                    const MocoVerifiedBadge(size: 15),
                  ],
                ],
              ),
              Text(
                formatRelativeTime(post.createdAt),
                style: const TextStyle(
                  color: MocoColors.textSecondary,
                  fontSize: 12,
                  shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (onTap == null) return content;

    return InkWell(
      key: Key('feed_author_${post.author.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(MocoRadius.pill),
      child: content,
    );
  }
}
