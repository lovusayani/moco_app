import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';
import '../../../core/theme/moco_spacing.dart';
import '../../../core/widgets/moco_avatar.dart';
import '../../../core/widgets/moco_surfaces.dart';
import '../../../shared/models/listener.dart';

/// How Discovery's grid is currently laid out — see [discoveryColumnsProvider].
/// Each density gets a genuinely different arrangement rather than the same
/// widget squeezed into a narrower column: 1-per-row is a horizontal "large"
/// card, 2-per-row is a taller vertical "medium" card with pill-style rates,
/// 3-per-row is the compact card the approved reference shows.
enum ListenerCardDensity { large, medium, compact }

/// Discovery grid card.
///
/// Every value shown comes from the backend response. The rate in particular is
/// per-listener server data, never a client constant — `listener_profiles`
/// allows custom rates, so a hardcoded 6/12 would mislead on any listener who
/// has one.
class ListenerCard extends StatelessWidget {
  const ListenerCard({
    super.key,
    required this.listener,
    required this.showVideoRate,
    this.firstCallFree = false,
    this.density = ListenerCardDensity.compact,
    this.onTap,
  });

  final ListenerSummary listener;

  /// Which rate the Audio/Video toggle is currently showing. Kept for
  /// backward compatibility with callers that still pass it; both rates are
  /// always shown regardless, since the backend returns both.
  final bool showVideoRate;

  /// Whether the SIGNED-IN USER still has their free first call. This is a
  /// property of the caller (`freeTrialAvailable` on /users/me), not of the
  /// listener — the backend exposes no per-listener eligibility.
  final bool firstCallFree;

  final ListenerCardDensity density;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return switch (density) {
      ListenerCardDensity.large => _LargeCard(
        listener: listener,
        firstCallFree: firstCallFree,
        onTap: onTap,
      ),
      ListenerCardDensity.medium => _MediumCard(
        listener: listener,
        firstCallFree: firstCallFree,
        onTap: onTap,
      ),
      ListenerCardDensity.compact => _CompactCard(
        listener: listener,
        firstCallFree: firstCallFree,
        onTap: onTap,
      ),
    };
  }
}

/// 3-per-row: the approved reference's compact card. Unchanged from the UI
/// parity pass — small avatar, stacked rate lines, tight type.
class _CompactCard extends StatelessWidget {
  const _CompactCard({required this.listener, required this.firstCallFree, this.onTap});

  final ListenerSummary listener;
  final bool firstCallFree;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(MocoSpacing.md),
      glow: listener.isAvailable,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Stack(
              children: [
                Center(
                  child: MocoAvatar(
                    name: listener.name,
                    imageUrl: listener.avatarUrl,
                    size: 88,
                    ring: listener.isAvailable,
                  ),
                ),
                if (listener.isOnline)
                  Positioned(top: 2, right: 2, child: _StatusPill(busy: listener.isBusy)),
                if (firstCallFree) const Positioned(top: 2, left: 2, child: _FreeBadge()),
              ],
            ),
          ),
          const SizedBox(height: MocoSpacing.sm),
          _NameRow(listener: listener, fontSize: 15, badgeSize: 14),
          if (listener.languages.isNotEmpty) _LanguagesLine(listener: listener, fontSize: 12),
          const SizedBox(height: MocoSpacing.sm),
          if (listener.rating > 0) _RatingRow(rating: listener.rating, fontSize: 12, iconSize: 13),
          const SizedBox(height: 3),
          _RateLine(rate: listener.audioRate, isVideo: false),
          const SizedBox(height: 2),
          _RateLine(rate: listener.videoRate, isVideo: true),
        ],
      ),
    );
  }
}

/// 2-per-row: a taller vertical card with more breathing room — bigger
/// avatar, both rates as a single pill row instead of stacked icon lines.
class _MediumCard extends StatelessWidget {
  const _MediumCard({required this.listener, required this.firstCallFree, this.onTap});

  final ListenerSummary listener;
  final bool firstCallFree;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(MocoSpacing.lg),
      glow: listener.isAvailable,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Stack(
              children: [
                Center(
                  child: MocoAvatar(
                    name: listener.name,
                    imageUrl: listener.avatarUrl,
                    size: 116,
                    ring: listener.isAvailable,
                  ),
                ),
                if (listener.isOnline)
                  Positioned(top: 4, right: 4, child: _StatusPill(busy: listener.isBusy)),
                if (firstCallFree) const Positioned(top: 4, left: 4, child: _FreeBadge()),
              ],
            ),
          ),
          const SizedBox(height: MocoSpacing.md),
          _NameRow(listener: listener, fontSize: 16.5, badgeSize: 16),
          if (listener.languages.isNotEmpty) _LanguagesLine(listener: listener, fontSize: 13),
          const SizedBox(height: MocoSpacing.sm),
          if (listener.rating > 0) _RatingRow(rating: listener.rating, fontSize: 13, iconSize: 14),
          const SizedBox(height: MocoSpacing.sm),
          Row(
            children: [
              _RatePill(rate: listener.audioRate, isVideo: false),
              const SizedBox(width: MocoSpacing.sm),
              _RatePill(rate: listener.videoRate, isVideo: true),
            ],
          ),
        ],
      ),
    );
  }
}

/// 1-per-row: a horizontal "large" card — the reference has room for this
/// layout only when there is a single column, so it is a genuinely different
/// arrangement (Row, not a stretched Column) rather than the same card
/// stretched wide.
class _LargeCard extends StatelessWidget {
  const _LargeCard({required this.listener, required this.firstCallFree, this.onTap});

  final ListenerSummary listener;
  final bool firstCallFree;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(MocoSpacing.lg),
      glow: listener.isAvailable,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              MocoAvatar(
                name: listener.name,
                imageUrl: listener.avatarUrl,
                size: 96,
                ring: listener.isAvailable,
              ),
              if (firstCallFree) const Positioned(top: -2, left: -2, child: _FreeBadge()),
            ],
          ),
          const SizedBox(width: MocoSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: _NameRow(listener: listener, fontSize: 18, badgeSize: 18)),
                    if (listener.isOnline) _StatusPill(busy: listener.isBusy),
                  ],
                ),
                if (listener.languages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _LanguagesLine(listener: listener, fontSize: 13.5),
                  ),
                const SizedBox(height: MocoSpacing.sm),
                if (listener.rating > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: MocoSpacing.sm),
                    child: _RatingRow(rating: listener.rating, fontSize: 13.5, iconSize: 15),
                  ),
                Row(
                  children: [
                    _RatePill(rate: listener.audioRate, isVideo: false),
                    const SizedBox(width: MocoSpacing.sm),
                    _RatePill(rate: listener.videoRate, isVideo: true),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _languageLabel(String code) => switch (code) {
  'hi' => 'हिंदी',
  'te' => 'తెలుగు',
  'en' => 'English',
  _ => code,
};

class _NameRow extends StatelessWidget {
  const _NameRow({required this.listener, required this.fontSize, required this.badgeSize});

  final ListenerSummary listener;
  final double fontSize;
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            listener.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MocoColors.textPrimary,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // Server-published boolean rather than an assumption about which
        // listeners discovery returns.
        if (listener.verified) ...[
          const SizedBox(width: 4),
          MocoVerifiedBadge(size: badgeSize),
        ],
      ],
    );
  }
}

class _LanguagesLine extends StatelessWidget {
  const _LanguagesLine({required this.listener, required this.fontSize});

  final ListenerSummary listener;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        listener.languages.map(_languageLabel).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: MocoColors.textMuted, fontSize: fontSize),
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.rating, required this.fontSize, required this.iconSize});

  final double rating;
  final double fontSize;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: iconSize, color: MocoColors.coinAccent),
        const SizedBox(width: 2),
        Text(
          rating.toStringAsFixed(1),
          style: TextStyle(
            color: MocoColors.textSecondary,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// A compact icon+rate line — used by the 3-column card, where there isn't
/// room for two full pills without truncating the price.
class _RateLine extends StatelessWidget {
  const _RateLine({required this.rate, required this.isVideo});

  final int rate;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          isVideo ? Icons.videocam_rounded : Icons.call_rounded,
          size: 10,
          color: MocoColors.coinAccent,
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            '$rate/min',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: MocoColors.coinAccent,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// A fuller pill — used by the 2- and 1-column cards, which have the width
/// to show both rates side by side rather than stacked lines.
class _RatePill extends StatelessWidget {
  const _RatePill({required this.rate, required this.isVideo});

  final int rate;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVideo ? Icons.videocam_rounded : Icons.call_rounded,
            size: 13,
            color: MocoColors.coinAccent,
          ),
          const SizedBox(width: 4),
          Text(
            '$rate/min',
            style: const TextStyle(
              color: MocoColors.coinAccent,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: MocoColors.backgroundPrimary.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MocoOnlineDot(online: !busy, size: 7),
          const SizedBox(width: 4),
          Text(
            busy ? 'Busy' : 'Online',
            style: TextStyle(
              color: busy ? MocoColors.textMuted : MocoColors.online,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FreeBadge extends StatelessWidget {
  const _FreeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        gradient: MocoColors.coinGradient,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
      ),
      child: const Text(
        '1st free',
        style: TextStyle(color: Color(0xFF2A1338), fontSize: 10, fontWeight: FontWeight.w800),
      ),
    );
  }
}
