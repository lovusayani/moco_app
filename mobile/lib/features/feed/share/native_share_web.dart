import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'native_share.dart';

/// `navigator.share`, where the browser has it. Must be called straight from
/// the tap handler: the browser only opens the sheet with a user gesture.
Future<NativeShareOutcome> shareNatively({
  required String title,
  required String text,
  required String url,
}) async {
  final navigator = web.window.navigator;
  if (!(navigator as JSObject).has('share')) {
    return NativeShareOutcome.unavailable;
  }
  final data = web.ShareData(title: title, text: text, url: url);
  try {
    if (navigator.has('canShare') && !navigator.canShare(data)) {
      return NativeShareOutcome.unavailable;
    }
    await navigator.share(data).toDart;
    return NativeShareOutcome.shared;
  } catch (error) {
    // AbortError is the user closing the sheet. Anything else (no gesture,
    // permission policy) falls back to copying the link.
    return error.toString().contains('AbortError')
        ? NativeShareOutcome.cancelled
        : NativeShareOutcome.unavailable;
  }
}
