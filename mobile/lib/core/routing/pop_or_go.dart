import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Leaves a full-screen route.
///
/// Natively a full-screen route is always pushed over something, so a plain
/// pop is enough. On web it can be the *only* page: opened by a refresh, a
/// deep link, or a shared URL. Popping then leaves an empty navigator — a
/// blank screen — so this goes to [fallback] instead.
void popOrGo(BuildContext context, String fallback) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
    return;
  }
  GoRouter.maybeOf(context)?.go(fallback);
}

/// AppBar `leading` for a full-screen route: null (the AppBar's own back
/// button) when there is a page underneath, otherwise a back button that goes
/// to [fallback] — without it a deep-linked screen would have no way back.
Widget? deepLinkBackButton(BuildContext context, String fallback) {
  if (Navigator.of(context).canPop()) return null;
  return BackButton(
    key: const Key('deep_link_back'),
    onPressed: () => GoRouter.maybeOf(context)?.go(fallback),
  );
}
