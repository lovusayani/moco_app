import 'native_share.dart';

/// No system share sheet outside the browser build; the caller copies the
/// link instead.
Future<NativeShareOutcome> shareNatively({
  required String title,
  required String text,
  required String url,
}) async => NativeShareOutcome.unavailable;
