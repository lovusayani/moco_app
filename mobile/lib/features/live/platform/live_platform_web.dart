import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../../shared/models/live.dart';

/// Opens the backend-provided provider URL in a new tab. `noopener` and
/// `noreferrer` keep the provider page from reaching back into Moco.
bool openLiveDestination(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return false;
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  return true;
}

final Set<String> _registered = {};

/// The official Stripchat player, exactly as the provider documents it —
/// `new StripchatPlayer({ modelName, userId, strict, autoplay })` after the
/// provider's script — inside its own sandboxed iframe document.
///
/// Why an iframe: the provider script expects a plain page, and Flutter Web
/// owns the main document. The iframe gives it one, isolated: its sandbox
/// has no `allow-same-origin`, so the provider's code cannot read Moco's
/// storage, cookies or session token. Only non-secret values from
/// `GET /api/live/config` are written into it.
///
/// With no script URL configured, [fallback] is shown instead — no guessed
/// script, no direct stream URL.
Widget stripchatPlayerView({
  required String modelName,
  required LivePlayerConfig config,
  required Widget fallback,
}) {
  final script = config.scriptUrl;
  if (script == null) return fallback;

  final options = jsonEncode({
    'modelName': modelName,
    'userId': config.userId,
    'strict': config.strict,
    'autoplay': config.autoplay,
  }).replaceAll('<', r'<');
  final src = jsonEncode(script).replaceAll('<', r'<');
  final doc =
      '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%;background:#000;color:#ddd;font:14px system-ui,sans-serif}
#msg{position:absolute;inset:0;display:grid;place-items:center;text-align:center;padding:16px}</style></head>
<body><div id="msg">Loading the live stream…</div><script>
(function(){
  var s=document.createElement('script');
  s.src=$src;
  s.onload=function(){
    try{ window.player=new StripchatPlayer($options); document.getElementById('msg').remove(); }
    catch(e){ document.getElementById('msg').textContent='The live player could not start.'; }
  };
  s.onerror=function(){ document.getElementById('msg').textContent='The live player could not be loaded.'; };
  document.body.appendChild(s);
})();
</script></body></html>''';

  final viewType = 'moco-live-player-${modelName.hashCode}-${doc.hashCode}';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final frame = web.HTMLIFrameElement()
        ..setAttribute(
          'sandbox',
          'allow-scripts allow-popups allow-popups-to-escape-sandbox allow-presentation',
        )
        ..setAttribute(
          'allow',
          'autoplay; fullscreen; encrypted-media; picture-in-picture',
        )
        ..setAttribute('referrerpolicy', 'no-referrer')
        ..setAttribute('title', 'Live stream of $modelName')
        ..srcdoc = doc.toJS;
      frame.style
        ..border = '0'
        ..width = '100%'
        ..height = '100%';
      return frame;
    });
  }
  return HtmlElementView(key: ValueKey(viewType), viewType: viewType);
}
