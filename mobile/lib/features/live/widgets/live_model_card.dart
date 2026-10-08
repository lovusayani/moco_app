import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';
import '../../../shared/models/live.dart';

/// A provider image, shown straight from the provider's URL (never
/// downloaded or re-hosted). On web it falls back to a plain <img> element
/// when the image host does not allow cross-origin reads, so provider CDNs
/// without CORS still display.
class LiveImage extends StatelessWidget {
  const LiveImage({super.key, required this.url, this.fit = BoxFit.cover});

  final String? url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [MocoColors.accentDeep, MocoColors.backgroundAccentStrong],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.sensors_rounded,
          color: MocoColors.textMuted,
          size: 28,
        ),
      ),
    );
    final u = url;
    if (u == null) return placeholder;
    return Image.network(
      u,
      fit: fit,
      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
      errorBuilder: (context, error, stack) => placeholder,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}

/// Country code → flag emoji (e.g. "co" → 🇨🇴); null for anything else.
String? countryFlag(String? code) {
  if (code == null || code.length != 2) return null;
  final c = code.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(c)) return null;
  return String.fromCharCodes(c.codeUnits.map((u) => 0x1F1E6 + u - 0x41));
}

String compactCount(int n) {
  if (n >= 1000000) {
    return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
  }
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
  return '$n';
}

class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, this.small = false});

  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('live_badge'),
      padding: EdgeInsets.symmetric(
        horizontal: small ? 5 : 7,
        vertical: small ? 1.5 : 2.5,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFE5304B),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: small ? 9 : 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
        child: child,
      ),
    );
  }
}

/// One live model, showing exactly the card fields the admin enabled, in the
/// admin's aspect, density and corner radius. [large] is the roomier
/// "Large cards" treatment (details under the image); [compact] trims the
/// overlay to one line.
class LiveModelCard extends StatelessWidget {
  const LiveModelCard({
    super.key,
    required this.model,
    required this.fields,
    required this.layout,
    required this.onTap,
    this.large = false,
    this.compact = false,
  });

  final LiveModel model;
  final LiveCardFields fields;
  final LiveLayout layout;
  final VoidCallback onTap;
  final bool large;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(layout.cornerRadius);
    final pad = layout.gap;
    final flag = fields.country ? countryFlag(model.country) : null;

    final topLeft = <Widget>[
      if (fields.liveBadge) LiveBadge(small: compact),
      if (fields.hdBadge && model.isHd)
        const _Pill(key: Key('hd_badge'), child: Text('HD')),
    ];
    final image = Stack(
      fit: StackFit.expand,
      children: [
        if (fields.snapshot)
          LiveImage(key: const Key('live_snapshot'), url: model.imageUrl)
        else
          LiveImage(url: fields.avatar ? model.avatarUrl : null),
        // Legibility scrim behind the overlay text.
        if (!large)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xB3000000),
                ],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
        if (topLeft.isNotEmpty)
          Positioned(
            top: pad * 0.6,
            left: pad * 0.6,
            child: Wrap(spacing: 4, runSpacing: 4, children: topLeft),
          ),
        if (fields.viewers)
          Positioned(
            top: pad * 0.6,
            right: pad * 0.6,
            child: _Pill(
              key: const Key('viewers'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.visibility_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 3),
                  Text(compactCount(model.viewers)),
                ],
              ),
            ),
          ),
        if (!large)
          Positioned(
            left: pad,
            right: pad,
            bottom: pad * 0.8,
            child: _details(context, flag, onImage: true),
          ),
      ],
    );

    return Semantics(
      button: true,
      label: 'Watch ${model.username} live',
      child: Material(
        color: MocoColors.surfaceGlass,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: model.featured
                ? MocoColors.accentPrimary.withValues(alpha: 0.7)
                : MocoColors.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('live_card_${model.username}'),
          onTap: onTap,
          child: large
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(aspectRatio: layout.aspectRatio, child: image),
                    Padding(
                      padding: EdgeInsets.all(pad),
                      child: _details(context, flag, onImage: false),
                    ),
                  ],
                )
              : image,
        ),
      ),
    );
  }

  Widget _details(BuildContext context, String? flag, {required bool onImage}) {
    final primary = onImage ? Colors.white : MocoColors.textPrimary;
    final secondary = onImage
        ? Colors.white.withValues(alpha: 0.82)
        : MocoColors.textSecondary;
    final nameSize = compact ? 12.0 : (large ? 15.0 : 13.5);
    final goal = fields.goal ? model.goal : null;

    final nameRow = Row(
      children: [
        if (fields.avatar) ...[
          ClipOval(
            key: const Key('live_avatar'),
            child: SizedBox(
              width: compact ? 18 : 22,
              height: compact ? 18 : 22,
              child: LiveImage(url: model.avatarUrl),
            ),
          ),
          const SizedBox(width: 6),
        ],
        if (fields.username)
          Flexible(
            child: Text(
              model.username,
              key: const Key('live_username'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: primary,
                fontSize: nameSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (flag != null) ...[
          const SizedBox(width: 5),
          Text(
            flag,
            key: const Key('live_country'),
            style: TextStyle(fontSize: nameSize),
          ),
        ],
      ],
    );

    if (compact) return nameRow;

    final meta = <String>[
      if (fields.languages && model.languages.isNotEmpty)
        model.languages.take(3).map((l) => l.toUpperCase()).join(' · '),
      if (fields.favorites) '♥ ${compactCount(model.favorites)}',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        nameRow,
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            meta.join('   '),
            key: const Key('live_meta'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 11),
          ),
        ],
        if (fields.tags && model.tags.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            key: const Key('live_tags'),
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final t in model.tags.take(large ? 4 : 2))
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: (onImage ? Colors.white : MocoColors.accentPrimary)
                        .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '#${t.split('/').last}',
                    style: TextStyle(
                      color: secondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (goal != null && goal.progress != null) ...[
          const SizedBox(height: 5),
          ClipRRect(
            key: const Key('live_goal'),
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: goal.progress,
              minHeight: 4,
              backgroundColor: (onImage ? Colors.white : MocoColors.textMuted)
                  .withValues(alpha: 0.22),
              color: MocoColors.accentPrimary,
            ),
          ),
          if (large && goal.message != null) ...[
            const SizedBox(height: 3),
            Text(
              goal.message!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: secondary, fontSize: 10.5),
            ),
          ],
        ],
      ],
    );
  }
}
