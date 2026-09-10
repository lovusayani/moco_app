import 'package:flutter/material.dart';

import '../../../core/theme/moco_colors.dart';

/// Filled circular call-control button (end/accept/decline). Distinct from
/// [MocoIconButton] because these carry call-specific semantic colour (red to
/// end/decline, green to accept) rather than the neutral glass styling used
/// everywhere else in the app.
class CallCircleButton extends StatelessWidget {
  const CallCircleButton({
    super.key,
    required this.icon,
    required this.color,
    this.onPressed,
    this.size = 64,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: color,
          shape: const CircleBorder(),
          elevation: 6,
          shadowColor: color.withValues(alpha: 0.6),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(icon, color: Colors.white, size: size * 0.42),
          ),
        ),
      ),
    );
  }
}

class EndCallButton extends StatelessWidget {
  const EndCallButton({super.key, this.onPressed, this.size = 64});

  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CallCircleButton(
      icon: Icons.call_end_rounded,
      color: MocoColors.danger,
      onPressed: onPressed,
      size: size,
    );
  }
}
