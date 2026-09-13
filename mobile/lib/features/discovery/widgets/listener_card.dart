import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';
import '../../../core/theme/moco_spacing.dart';
import '../../../core/widgets/moco_avatar.dart';
import '../../../core/widgets/moco_surfaces.dart';
import '../../../shared/models/listener.dart';

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
    this.onTap,
  });

  final ListenerSummary listener;

  /// Which rate the Audio/Video toggle is currently showing.
  final bool showVideoRate;

  /// Whether the SIGNED-IN USER still has their free first call. This is a
  /// property of the caller (`freeTrialAvailable` on /users/me), not of the
  /// listener — the backend exposes no per-listener eligibility.
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
                  Positioned(
                    top: 2,
                    right: 2,
                    child: _StatusPill(busy: listener.isBusy),
                  ),
                if (firstCallFree)
                  const Positioned(top: 2, left: 2, child: _FreeBadge()),
              ],
            ),
          ),
          const SizedBox(height: MocoSpacing.sm),
          Row(
            children: [
              Flexible(
                child: Text(
                  listener.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Server-published boolean rather than an assumption about which
              // listeners discovery returns.
              if (listener.verified) ...[
                const SizedBox(width: 4),
                const MocoVerifiedBadge(size: 14),
              ],
            ],
          ),
          if (listener.languages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                listener.languages.map(_languageLabel).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: MocoColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: MocoSpacing.sm),
          if (listener.rating > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.star_rounded,
                  size: 13,
                  color: MocoColors.coinAccent,
                ),
                const SizedBox(width: 2),
                Text(
                  listener.rating.toStringAsFixed(1),
                  style: const TextStyle(
                    color: MocoColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 3),
          // Both rates, always — the audio/video toggle up in the header
          // still reaches the server as a real capability filter (unchanged);
          // it no longer decides which single rate this card can show, since
          // the backend already returns both on every listener.
          _RateLine(rate: listener.audioRate, isVideo: false),
          const SizedBox(height: 2),
          _RateLine(rate: listener.videoRate, isVideo: true),
        ],
      ),
    );
  }

  static String _languageLabel(String code) => switch (code) {
    'hi' => 'हिंदी',
    'te' => 'తెలుగు',
    'en' => 'English',
    _ => code,
  };
}

/// A compact icon+rate line — the reference shows both audio and video rates
/// stacked, rather than one pill sized for a 2-column card, so this is a
/// plain row rather than the old badge-shaped pill (there isn't room for two
/// pills at 3-column width without truncating the price).
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
        style: TextStyle(
          color: Color(0xFF2A1338),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
