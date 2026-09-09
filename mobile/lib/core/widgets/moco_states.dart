import 'package:flutter/material.dart';

import '../theme/moco_colors.dart';
import '../theme/moco_spacing.dart';
import 'moco_surfaces.dart';

/// Shimmering placeholder block used to build loading skeletons.
///
/// One animation controller drives the whole skeleton via a shared ticker
/// rather than one per block, so a grid of twenty cards is still one animation.
class MocoSkeleton extends StatefulWidget {
  const MocoSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = MocoRadius.sm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<MocoSkeleton> createState() => _MocoSkeletonState();
}

class _MocoSkeletonState extends State<MocoSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    // Respect reduced motion: a static block is a valid skeleton.
    if (!WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: MocoColors.surfaceGlass.withValues(
              alpha: 0.06 + (_controller.value * 0.06),
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

/// Retry block shown when a request fails. Takes an already-humanised message —
/// raw server text never reaches this widget.
class MocoErrorState extends StatelessWidget {
  const MocoErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.title = 'Something went wrong',
    this.icon = Icons.wifi_off_rounded,
  });

  final String message;
  final VoidCallback? onRetry;
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MocoSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MocoColors.surfaceGlass,
                border: Border.all(color: MocoColors.borderSubtle),
              ),
              child: Icon(icon, color: MocoColors.textMuted, size: 27),
            ),
            const SizedBox(height: MocoSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: MocoSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MocoColors.textMuted,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: MocoSpacing.xl),
              MocoSecondaryButton(
                label: 'Try again',
                icon: Icons.refresh_rounded,
                expand: false,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Empty result state.
class MocoEmptyState extends StatelessWidget {
  const MocoEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.search_off_rounded,
    this.action,
  });

  final String title;
  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MocoSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: MocoColors.textMuted),
            const SizedBox(height: MocoSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: MocoSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MocoColors.textMuted,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: MocoSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Marks a screen that exists only so navigation is complete. Never shipped as
/// a real feature — production builds gate these behind Env.showDevPlaceholders.
class MocoPlaceholderState extends StatelessWidget {
  const MocoPlaceholderState({
    super.key,
    required this.feature,
    required this.phase,
  });

  final String feature;
  final String phase;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MocoSpacing.xl),
        child: MocoGlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.construction_rounded,
                size: 34,
                color: MocoColors.warning,
              ),
              const SizedBox(height: MocoSpacing.md),
              Text(
                feature,
                style: const TextStyle(
                  color: MocoColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: MocoSpacing.xs),
              Text(
                'Arrives in $phase.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MocoColors.textMuted,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
