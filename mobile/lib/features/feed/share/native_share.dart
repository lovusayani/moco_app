/// The system share sheet: the Web Share API in a browser that has one,
/// unavailable elsewhere (the caller then copies the link instead).
library;

export 'native_share_stub.dart'
    if (dart.library.js_interop) 'native_share_web.dart';

/// How a native share attempt ended.
enum NativeShareOutcome {
  /// The share sheet completed — the user picked a target.
  shared,

  /// The user closed the share sheet. Nothing was shared.
  cancelled,

  /// No share sheet here (or it refused); copy the link instead.
  unavailable,
}
