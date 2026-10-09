import 'package:flutter/widgets.dart';

import '../../../shared/models/live.dart';

/// Not available off the web: nothing is opened.
bool openLiveDestination(String url) => false;

/// Not available off the web: always the fallback.
Widget stripchatPlayerView({
  required String modelName,
  required LivePlayerConfig config,
  required Widget fallback,
  VoidCallback? onExit,
}) => fallback;
