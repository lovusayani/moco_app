import 'package:flutter/material.dart';

import '../theme/moco_colors.dart';

/// How much atmosphere a screen gets.
///
/// Discovery is the showcase and earns the strongest treatment; forms stay calm
/// so inputs remain the focus.
enum MocoAmbience { calm, standard, rich }

/// The app's ambient ground: a plum gradient with rose and copper glows.
///
/// Implemented with painted gradients rather than blur filters. A `BackdropFilter`
/// spanning the whole screen is one of the most expensive things a Flutter app
/// can do per frame, and on the low-end Android hardware this app targets it
/// would cost frames for no visual gain — these radial gradients read the same.
class MocoBackground extends StatelessWidget {
  const MocoBackground({
    super.key,
    required this.child,
    this.ambience = MocoAmbience.standard,
  });

  final Widget child;
  final MocoAmbience ambience;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: MocoColors.backgroundGradient),
      child: Stack(
        children: [
          if (ambience != MocoAmbience.calm)
            Positioned(
              top: -140,
              left: -90,
              child: _Glow(
                color: MocoColors.glowRose,
                size: ambience == MocoAmbience.rich ? 400 : 320,
              ),
            ),
          if (ambience == MocoAmbience.rich)
            Positioned(
              bottom: -120,
              right: -110,
              child: _Glow(color: MocoColors.glowCopper, size: 360),
            ),
          if (ambience != MocoAmbience.calm)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _CurvedHighlight(),
            ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}

/// A soft curved band across the top, giving the ground some structure without
/// another full-size gradient.
class _CurvedHighlight extends StatelessWidget {
  const _CurvedHighlight();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: 220,
        child: CustomPaint(painter: _CurvePainter()),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          MocoColors.accentDeep.withValues(alpha: 0.35),
          MocoColors.accentDeep.withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.62)
      ..quadraticBezierTo(size.width * 0.5, size.height, 0, size.height * 0.62)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter oldDelegate) => false;
}
