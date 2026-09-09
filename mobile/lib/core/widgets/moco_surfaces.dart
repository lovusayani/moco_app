import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/moco_colors.dart';
import '../theme/moco_spacing.dart';

/// Translucent card.
///
/// `blur` is opt-in and off by default. A translucent fill over the ambient
/// background already reads as glass; a real `BackdropFilter` costs a saveLayer
/// per card, which is ruinous inside a scrolling grid. Blur is reserved for the
/// few places a card sits over live content.
class MocoGlassCard extends StatelessWidget {
  const MocoGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(MocoSpacing.lg),
    this.radius = MocoRadius.lg,
    this.strong = false,
    this.blur = false,
    this.glow = false,
    this.border = true,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool strong;
  final bool blur;
  final bool glow;
  final bool border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: strong ? MocoColors.surfaceGlassStrong : MocoColors.surfaceGlass,
        borderRadius: shape,
        border: border
            ? Border.all(
                color: glow
                    ? MocoColors.accentPrimary.withValues(alpha: 0.55)
                    : MocoColors.borderSubtle,
                width: glow ? 1.4 : 1,
              )
            : null,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: MocoColors.accentPrimary.withValues(alpha: 0.22),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );

    if (blur) {
      surface = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: surface,
        ),
      );
    }

    if (onTap == null) return surface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: shape,
        splashColor: MocoColors.accentPrimary.withValues(alpha: 0.12),
        highlightColor: MocoColors.surfaceGlassPressed,
        child: surface,
      ),
    );
  }
}

/// Filled primary action. Owns its own busy state so callers never have to
/// swap the widget out mid-press.
class MocoPrimaryButton extends StatelessWidget {
  const MocoPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SizedBox(
        width: expand ? double.infinity : null,
        height: 54,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              gradient: MocoColors.accentGradient,
              borderRadius: BorderRadius.circular(MocoRadius.md),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: MocoColors.accentPrimary.withValues(alpha: 0.32),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: InkWell(
              onTap: enabled ? onPressed : null,
              borderRadius: BorderRadius.circular(MocoRadius.md),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation(
                            MocoColors.textOnAccent,
                          ),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(
                              icon,
                              size: 20,
                              color: MocoColors.textOnAccent,
                            ),
                            const SizedBox(width: MocoSpacing.sm),
                          ],
                          Text(
                            label,
                            style: const TextStyle(
                              color: MocoColors.textOnAccent,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlined secondary action.
class MocoSecondaryButton extends StatelessWidget {
  const MocoSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: SizedBox(
        width: expand ? double.infinity : null,
        height: 54,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 20),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: MocoColors.textPrimary,
            side: const BorderSide(color: MocoColors.borderStrong),
            backgroundColor: MocoColors.surfaceGlass,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MocoRadius.md),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular icon button on a glass surface.
class MocoIconButton extends StatelessWidget {
  const MocoIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.active = false,
    this.size = MocoSpacing.minTouchTarget,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: active
            ? MocoColors.accentPrimary.withValues(alpha: 0.18)
            : MocoColors.surfaceGlass,
        shape: CircleBorder(
          side: BorderSide(
            color: active ? MocoColors.accentPrimary : MocoColors.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Icon(
            icon,
            size: size * 0.44,
            color: active ? MocoColors.accentPrimary : MocoColors.textSecondary,
          ),
        ),
      ),
    );

    return Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: tooltip == null
          ? button
          : Tooltip(message: tooltip!, child: button),
    );
  }
}

/// Filter/selection chip with the design system's glowing selected border.
class MocoChip extends StatelessWidget {
  const MocoChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: MocoDuration.tab,
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected
            ? MocoColors.accentPrimary.withValues(alpha: 0.16)
            : MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(
          color: selected ? MocoColors.accentPrimary : MocoColors.borderSubtle,
          width: selected ? 1.4 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: MocoColors.accentPrimary.withValues(alpha: 0.22),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MocoRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MocoSpacing.lg,
              vertical: 10,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 15,
                    color: selected
                        ? MocoColors.accentPrimary
                        : MocoColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? MocoColors.textPrimary
                        : MocoColors.textSecondary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Section heading with an optional trailing action.
class MocoSectionHeader extends StatelessWidget {
  const MocoSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.subtitle,
  });

  final String title;
  final Widget? action;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: MocoColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: const TextStyle(
                      color: MocoColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}
