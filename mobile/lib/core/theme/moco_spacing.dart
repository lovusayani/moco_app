/// Presentation-only constants.
///
/// Business values (rates, coin packs, balances) are never duplicated here —
/// those come from the backend on every request.
class MocoSpacing {
  const MocoSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Screen gutter used by every full-width screen.
  static const double screenPadding = 20;

  /// The Material minimum touch target; nothing tappable goes below it.
  static const double minTouchTarget = 48;
}

class MocoRadius {
  const MocoRadius._();

  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;
  static const double pill = 999;
}

/// Motion durations. Restrained by design: long or continuous animation on a
/// low-end Android device costs frames the call UI will need later.
class MocoDuration {
  const MocoDuration._();

  static const Duration press = Duration(milliseconds: 140);
  static const Duration tab = Duration(milliseconds: 200);
  static const Duration sheet = Duration(milliseconds: 260);
  static const Duration onboarding = Duration(milliseconds: 380);
}
