import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';
import '../../../shared/models/feed.dart';

/// The Feed's right-hand controls, floating over the media:
/// compose · follow · like · comment · share.
///
/// Fixed light-on-dark styling rather than theme colours: it always sits on
/// top of a photo or video, never on the app background.
class FeedActionStack extends StatelessWidget {
  const FeedActionStack({
    super.key,
    required this.post,
    required this.onCompose,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    this.onFollow,
    this.compact = false,
  });

  final Post post;
  final VoidCallback onCompose;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;

  /// Null hides Follow: your own post, or an author who cannot be followed.
  final VoidCallback? onFollow;

  /// Smaller buttons and gaps for short viewports.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 40.0 : 46.0;
    final gap = compact ? 8.0 : 12.0;

    return Column(
      key: const Key('feed_action_stack'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          buttonKey: const Key('feed_compose_button'),
          semanticLabel: 'Create a post',
          size: size,
          highlighted: true,
          onTap: onCompose,
          child: Icon(
            Icons.add_rounded,
            color: Colors.white,
            size: size * 0.54,
          ),
        ),
        if (onFollow != null) ...[
          SizedBox(height: gap),
          _FollowButton(
            following: post.author.isFollowing,
            size: size,
            onTap: onFollow!,
          ),
        ],
        SizedBox(height: gap),
        _LikeButton(
          liked: post.liked,
          count: post.likeCount,
          size: size,
          onTap: onLike,
        ),
        SizedBox(height: gap),
        _ActionButton(
          buttonKey: const Key('feed_comment_button'),
          semanticLabel: 'Comments',
          size: size,
          onTap: onComment,
          label: _Count(
            post.commentCount,
            countKey: const Key('feed_comment_count'),
          ),
          child: Icon(
            Icons.chat_bubble_rounded,
            color: Colors.white,
            size: size * 0.46,
          ),
        ),
        SizedBox(height: gap),
        _ActionButton(
          buttonKey: const Key('feed_share_button'),
          semanticLabel: 'Share',
          size: size,
          onTap: onShare,
          label: _Count(
            post.shareCount,
            countKey: const Key('feed_share_count'),
          ),
          child: Icon(
            Icons.share_rounded,
            color: Colors.white,
            size: size * 0.44,
          ),
        ),
      ],
    );
  }
}

const _purple = Color(0xFF8E5CF7);

const _glassFill = Color(0x52000000);
final _glassBorder = Colors.white.withValues(alpha: 0.18);

/// One round glass control with an optional count underneath.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.buttonKey,
    required this.semanticLabel,
    required this.size,
    required this.onTap,
    required this.child,
    this.label,
    this.highlighted = false,
  });

  final Key buttonKey;
  final String semanticLabel;
  final double size;
  final VoidCallback onTap;
  final Widget child;
  final Widget? label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final gradient = highlighted
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [MocoColors.accentPrimary, _purple],
          )
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: semanticLabel,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              key: buttonKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: gradient == null ? _glassFill : null,
                  gradient: gradient,
                  border: Border.all(
                    color: gradient == null
                        ? _glassBorder
                        : Colors.white.withValues(alpha: 0.28),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (gradient == null
                                  ? Colors.black
                                  : MocoColors.accentPrimary)
                              .withValues(
                                alpha: gradient == null ? 0.18 : 0.38,
                              ),
                      blurRadius: gradient == null ? 10 : 16,
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        ),
        if (label != null) ...[const SizedBox(height: 3), label!],
      ],
    );
  }
}

class _FollowButton extends StatelessWidget {
  const _FollowButton({
    required this.following,
    required this.size,
    required this.onTap,
  });

  final bool following;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ActionButton(
      buttonKey: const Key('feed_follow_button'),
      semanticLabel: following ? 'Unfollow' : 'Follow',
      size: size,
      onTap: onTap,
      highlighted: !following,
      label: _Label(
        following ? 'Following' : 'Follow',
        textKey: const Key('feed_follow_label'),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(
          following ? Icons.how_to_reg_rounded : Icons.person_add_alt_1_rounded,
          key: ValueKey(following),
          color: Colors.white,
          size: size * 0.46,
        ),
      ),
    );
  }
}

/// Like, with a short pop when it turns on.
class _LikeButton extends StatefulWidget {
  const _LikeButton({
    required this.liked,
    required this.count,
    required this.size,
    required this.onTap,
  });

  final bool liked;
  final int count;
  final double size;
  final VoidCallback onTap;

  @override
  State<_LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<_LikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.28), weight: 45),
    TweenSequenceItem(tween: Tween(begin: 1.28, end: 1), weight: 55),
  ]).animate(CurvedAnimation(parent: _pop, curve: Curves.easeOut));

  @override
  void didUpdateWidget(_LikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.liked && !oldWidget.liked) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ActionButton(
      buttonKey: const Key('feed_like_button'),
      semanticLabel: widget.liked ? 'Unlike' : 'Like',
      size: widget.size,
      onTap: widget.onTap,
      label: _Count(widget.count, countKey: const Key('feed_like_count')),
      child: ScaleTransition(
        scale: _scale,
        child: ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) =>
              (widget.liked
                      ? const LinearGradient(
                          colors: [MocoColors.accentSoft, _purple],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : const LinearGradient(
                          colors: [Colors.white, Colors.white],
                        ))
                  .createShader(rect),
          child: Icon(
            widget.liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            key: Key(widget.liked ? 'feed_like_on' : 'feed_like_off'),
            size: widget.size * 0.5,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value, {required this.countKey});

  final int value;
  final Key countKey;

  @override
  Widget build(BuildContext context) =>
      _Label(formatCompactCount(value), textKey: countKey);
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.textKey});

  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      key: textKey,
      maxLines: 1,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        shadows: [Shadow(color: Color(0xAA000000), blurRadius: 6)],
      ),
    );
  }
}

/// 999 → "999", 1200 → "1.2K", 3400000 → "3.4M".
String formatCompactCount(int value) {
  String short(double v, String unit) {
    final text = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}$unit';
  }

  if (value >= 1000000) return short(value / 1000000, 'M');
  if (value >= 1000) return short(value / 1000, 'K');
  return '$value';
}
