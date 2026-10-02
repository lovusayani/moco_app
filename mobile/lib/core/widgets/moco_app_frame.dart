import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/moco_colors.dart';

/// Keeps the phone layout a phone layout on wide browser windows.
///
/// Every screen is designed for a ~390px phone. On a tablet or desktop browser
/// the app is shown as a centred column no wider than [maxWidth], over the
/// app's own background, instead of stretching cards and the floating nav bar
/// across the whole window. Below [maxWidth] — any phone, or a narrow window —
/// this is a no-op, so the mobile layout is exactly the native one.
///
/// The column gets its own [MediaQuery] size, so screens that size themselves
/// from `MediaQuery.sizeOf` (the snap feed, sheets, dialogs) see the column,
/// not the window. It wraps the whole Navigator, so dialogs, bottom sheets and
/// snackbars stay inside the column too.
class MocoAppFrame extends StatelessWidget {
  const MocoAppFrame({super.key, required this.child, this.maxWidth = 600});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= maxWidth) return child;

    return ColoredBox(
      key: const Key('moco_app_frame'),
      color: MocoColors.backgroundPrimary,
      child: Center(
        child: Container(
          width: maxWidth,
          decoration: BoxDecoration(
            border: Border.symmetric(
              vertical: BorderSide(color: MocoColors.borderSubtle),
            ),
          ),
          child: ClipRect(
            child: MediaQuery(
              data: media.copyWith(size: Size(maxWidth, media.size.height)),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Lets a mouse or trackpad drag-scroll like a finger on web, so the snap
/// feed and horizontal carousels work in a desktop browser. Touch behaviour is
/// unchanged.
class MocoWebScrollBehavior extends MaterialScrollBehavior {
  const MocoWebScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
