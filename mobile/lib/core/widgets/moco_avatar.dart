import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/moco_colors.dart';

/// Avatar with a deterministic fallback.
///
/// A missing or broken URL must never crash or leave a hole: the fallback is a
/// gradient tinted from the name, so the same person always gets the same
/// colour and the grid stays visually stable while images load.
class MocoAvatar extends StatelessWidget {
  const MocoAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 48,
    this.ring = false,
  });

  final String name;
  final String? imageUrl;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final content = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: (imageUrl == null || imageUrl!.isEmpty)
            ? _Fallback(name: name, size: size)
            : CachedNetworkImage(
                imageUrl: imageUrl!,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 180),
                placeholder: (_, __) => _Fallback(name: name, size: size),
                errorWidget: (_, __, ___) => _Fallback(name: name, size: size),
              ),
      ),
    );

    if (!ring) return content;

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: MocoColors.accentGradient,
        boxShadow: [
          BoxShadow(
            color: MocoColors.accentPrimary.withValues(alpha: 0.35),
            blurRadius: 18,
          ),
        ],
      ),
      child: content,
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();

    // Stable hue per name so avatars do not flicker between rebuilds.
    final hue = (trimmed.hashCode.abs() % 60) + 300.0;
    final base = HSLColor.fromAHSL(1, hue % 360, 0.45, 0.34).toColor();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, MocoColors.accentDeep],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: MocoColors.textPrimary,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Verified marker.
///
/// The backend only ever returns KYC-approved listeners from discovery, so
/// every listener the client can see is verified by construction. There is no
/// per-listener `verified` field to read (see mobile/README.md, API gaps).
class MocoVerifiedBadge extends StatelessWidget {
  const MocoVerifiedBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Identity verified',
      child: Icon(
        Icons.verified_rounded,
        size: size,
        color: MocoColors.accentSoft,
      ),
    );
  }
}

/// Presence dot.
class MocoOnlineDot extends StatelessWidget {
  const MocoOnlineDot({super.key, this.online = true, this.size = 10});

  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = online ? MocoColors.online : MocoColors.textMuted;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: online
            ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)]
            : null,
      ),
    );
  }
}
