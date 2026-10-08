import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../config/env.dart';

/// Crash and error reporting (Sentry), for the web app and Android.
///
/// Enabled only when the build passes `--dart-define=SENTRY_DSN=...` (a DSN is
/// a public client identifier, not a secret). Without it this is a no-op and
/// the app runs exactly as before.
///
/// Reports carry the error, its stack trace, the release and environment, the
/// platform, and the signed-in user's numeric id. They never carry request
/// bodies, headers, cookies, IP addresses, typed text (sign-in codes, chat
/// messages), the session token, or query strings.
class Monitoring {
  const Monitoring._();

  static const _dsn = String.fromEnvironment('SENTRY_DSN');

  /// Set by the web build to the deployed commit. Android builds fall back
  /// to Sentry's default, the app id and version from the APK.
  static const _release = String.fromEnvironment('MOCO_RELEASE');

  static bool get enabled => _dsn.isNotEmpty;

  /// Runs [appRunner] with error reporting attached: uncaught Dart errors,
  /// Flutter framework errors, and (on Android) native crashes.
  static Future<void> run(FutureOr<void> Function() appRunner) async {
    if (!enabled) {
      await appRunner();
      return;
    }
    await SentryFlutter.init((options) {
      options.dsn = _dsn;
      options.environment = Env.flavor.name;
      if (_release.isNotEmpty) options.release = _release;
      options.sendDefaultPii = false;
      options.maxRequestBodySize = MaxRequestBodySize.never;
      options.beforeBreadcrumb = scrubBreadcrumb;
      options.beforeSend = scrubEvent;
    }, appRunner: appRunner);
    _maybeSendTestEvent();
  }

  /// Ties later reports to the signed-in account by numeric id only.
  static void setUser(int? id) {
    if (!enabled) return;
    Sentry.configureScope(
      (scope) => scope.setUser(id == null ? null : SentryUser(id: '$id')),
    );
  }

  /// Web: opening the app with `?moco_monitoring_test=1` sends one test
  /// event, to check the pipeline end to end after configuring a DSN.
  static void _maybeSendTestEvent() {
    if (!kIsWeb) return;
    if (Uri.base.queryParameters['moco_monitoring_test'] != '1') return;
    Sentry.captureMessage(
      'Moco monitoring test event (web)',
      level: SentryLevel.info,
    );
  }

  /// Strips query strings from any URL a breadcrumb records, and drops
  /// request/response bodies.
  @visibleForTesting
  static Breadcrumb? scrubBreadcrumb(Breadcrumb? crumb, Hint hint) {
    if (crumb == null) return null;
    final data = crumb.data;
    if (data == null || data.isEmpty) return crumb;
    final clean = <String, dynamic>{};
    data.forEach((key, value) {
      if (key == 'body' || key == 'request_body' || key == 'response_body') {
        return;
      }
      clean[key] = value is String && key == 'url' ? stripQuery(value) : value;
    });
    crumb.data = clean;
    return crumb;
  }

  /// Removes anything request-shaped from an event: body, headers, cookies,
  /// query string. The rest of the event (error, stack, tags) is kept.
  @visibleForTesting
  static FutureOr<SentryEvent?> scrubEvent(SentryEvent event, Hint hint) {
    final request = event.request;
    if (request == null) return event;
    event.request = SentryRequest(
      url: request.url == null ? null : stripQuery(request.url!),
      method: request.method,
    );
    return event;
  }

  @visibleForTesting
  static String stripQuery(String url) {
    final q = url.indexOf('?');
    final h = url.indexOf('#');
    final cut = [
      q,
      h,
    ].where((i) => i >= 0).fold<int>(url.length, (a, b) => a < b ? a : b);
    return url.substring(0, cut);
  }
}
