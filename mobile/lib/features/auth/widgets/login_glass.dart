import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';

/// Liquid-glass building blocks for the web login screen. Kept local to auth:
/// they are tuned for sitting on a full-screen photo/video, not app chrome.

bool reduceMotion(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

/// A frosted, translucent capsule/rounded surface.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = EdgeInsets.zero,
    this.highlighted = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// A brighter rim, e.g. while the field has focus.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: shape,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.06),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(
                  alpha: highlighted ? 0.42 : 0.20,
                ),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Two-segment capsule toggle with a sliding glass thumb.
class GlassSegmented<T> extends StatelessWidget {
  const GlassSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.isEnabled,
    this.keyOf,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final bool Function(T)? isEnabled;
  final Key Function(T)? keyOf;

  @override
  Widget build(BuildContext context) {
    final index = values.indexOf(selected).clamp(0, values.length - 1);
    final motion = reduceMotion(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return GlassSurface(
      radius: 999,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 40,
        child: Stack(
          children: [
            AnimatedAlign(
              duration: motion,
              curve: Curves.easeOutCubic,
              alignment: Alignment(
                values.length == 1 ? 0 : -1 + 2 * index / (values.length - 1),
                0,
              ),
              child: FractionallySizedBox(
                widthFactor: 1 / values.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Colors.white.withValues(alpha: 0.22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.30),
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (final value in values)
                  Expanded(child: _segment(context, value, motion)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, T value, Duration motion) {
    final isSelected = value == selected;
    final enabled = isEnabled?.call(value) ?? true;
    final label = labelOf(value);
    return Semantics(
      button: true,
      selected: isSelected,
      enabled: enabled,
      label: enabled ? label : '$label, coming soon',
      excludeSemantics: true,
      child: InkWell(
        key: keyOf?.call(value),
        borderRadius: BorderRadius.circular(999),
        onTap: enabled && !isSelected ? () => onChanged(value) : null,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: motion,
            style: TextStyle(
              color: !enabled
                  ? Colors.white.withValues(alpha: 0.35)
                  : isSelected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.72),
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.2,
            ),
            child: Text(enabled ? label : '$label · soon'),
          ),
        ),
      ),
    );
  }
}

/// The compact capsule action: arrow icon, gradient, hover glow and a
/// spring-y press. Keyboard: focusable, Enter/Space activate (InkWell).
class PillActionButton extends StatefulWidget {
  const PillActionButton({
    super.key,
    required this.onPressed,
    this.loading = false,
    this.semanticLabel = 'Continue',
  });

  final VoidCallback? onPressed;
  final bool loading;
  final String semanticLabel;

  @override
  State<PillActionButton> createState() => _PillActionButtonState();
}

class _PillActionButtonState extends State<PillActionButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final motion = reduceMotion(context);
    final scale = !enabled || motion
        ? 1.0
        : _pressed
        ? 0.94
        : _hover
        ? 1.04
        : 1.0;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: AnimatedScale(
        scale: scale,
        duration: Duration(milliseconds: motion ? 0 : (_pressed ? 90 : 260)),
        curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: enabled || widget.loading ? 1 : 0.45,
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 104,
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: const LinearGradient(
                colors: [Color(0xFFC8095F), Color(0xFFF2468F)],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
              boxShadow: [
                BoxShadow(
                  color: MocoColors.accentPrimary.withValues(
                    alpha: enabled && _hover ? 0.55 : 0.30,
                  ),
                  blurRadius: enabled && _hover ? 26 : 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: enabled ? widget.onPressed : null,
                onHover: (v) => setState(() => _hover = v),
                onHighlightChanged: (v) => setState(() => _pressed = v),
                child: Center(
                  child: widget.loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft fade + rise on first build, staggered by [delay].
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  static const _run = Duration(milliseconds: 520);

  // One controller covering delay + run; the delay is an Interval, not a
  // timer, so nothing is left pending if the screen goes away early.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.delay + _run,
  );
  late final Animation<double> _curved = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.delay.inMilliseconds / (widget.delay + _run).inMilliseconds,
      1,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.value = 1;
    } else if (_c.status == AnimationStatus.dismissed) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}
