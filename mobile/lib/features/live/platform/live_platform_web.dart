import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../../core/config/env.dart';
import '../../../core/theme/moco_colors.dart';
import '../../../shared/models/live.dart';

/// Opens the backend-provided provider URL in a new tab. `noopener` and
/// `noreferrer` keep the provider page from reaching back into Moco.
bool openLiveDestination(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return false;
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  return true;
}

/// The official Stripchat player for [modelName].
///
/// The player runs in an iframe whose page is served by the API
/// (`GET /api/live/player-frame`, on api.lovcamx.online in production — a
/// different origin from the web app, so the provider's code cannot reach
/// Moco's storage or session). That page loads the provider script once and
/// creates `new StripchatPlayer({...}).mount(...)`; this widget only tells it
/// which model to show and listens to its events:
///
///  * a new [modelName] → the page destroys the current player
///    (`app.destroy()`) and mounts the next one;
///  * leaving the screen → `destroy` is sent, then the iframe is removed;
///  * `offline` / `unavailable` errors → a message and a way back to Live
///    (never a silent switch to another model — this one was chosen);
///  * `playback` errors → the player is left to recover; a fatal one offers
///    "Try again"; `fullscreen` errors → a short notice only.
///
/// Without a configured script, [fallback] is shown: no guessed script and
/// no raw stream URLs.
Widget stripchatPlayerView({
  required String modelName,
  required LivePlayerConfig config,
  required Widget fallback,
  VoidCallback? onExit,
}) {
  if (!config.available) return fallback;
  return _StripchatPlayer(
    key: const ValueKey('live_player_frame'),
    modelName: modelName,
    config: config,
    onExit: onExit,
  );
}

enum _Phase { loading, ready, offline, unavailable, interrupted, failed }

class _StripchatPlayer extends StatefulWidget {
  const _StripchatPlayer({
    super.key,
    required this.modelName,
    required this.config,
    this.onExit,
  });

  final String modelName;
  final LivePlayerConfig config;
  final VoidCallback? onExit;

  @override
  State<_StripchatPlayer> createState() => _StripchatPlayerState();
}

class _StripchatPlayerState extends State<_StripchatPlayer> {
  static int _instances = 0;

  late final String _viewType;
  late final Uri _frameUrl;
  web.HTMLIFrameElement? _frame;
  JSFunction? _onMessage;
  Timer? _watchdog;
  _Phase _phase = _Phase.loading;

  @override
  void initState() {
    super.initState();
    _frameUrl = Uri.parse('${Env.apiBaseUrl}${widget.config.framePath}');
    // One view type per player instance: each screen gets its own iframe,
    // removed by Flutter when the screen goes away.
    _viewType = 'moco-live-player-${_instances++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final frame = web.HTMLIFrameElement()
        // Its own origin (allow-same-origin keeps the API's origin, not
        // Moco's); no top navigation; popups only for the provider's links.
        ..setAttribute(
          'sandbox',
          'allow-scripts allow-same-origin allow-popups '
              'allow-popups-to-escape-sandbox allow-presentation',
        )
        ..setAttribute(
          'allow',
          'autoplay; fullscreen; encrypted-media; picture-in-picture',
        )
        ..setAttribute('allowfullscreen', '')
        ..setAttribute('title', 'Live stream of ${widget.modelName}')
        ..src = _frameUrl.toString();
      frame.style
        ..border = '0'
        ..width = '100%'
        ..height = '100%'
        ..display = 'block';
      frame.addEventListener(
        'load',
        ((web.Event _) => _load(widget.modelName)).toJS,
      );
      _frame = frame;
      return frame;
    });
    _onMessage = _handleMessage.toJS;
    web.window.addEventListener('message', _onMessage);
    _armWatchdog();
  }

  @override
  void didUpdateWidget(covariant _StripchatPlayer old) {
    super.didUpdateWidget(old);
    if (old.modelName != widget.modelName) _load(widget.modelName);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _send({'type': 'destroy'});
    if (_onMessage != null) {
      web.window.removeEventListener('message', _onMessage);
    }
    _frame = null;
    super.dispose();
  }

  void _send(Map<String, Object?> message) {
    final target = _frame?.contentWindow;
    if (target == null) return;
    target.postMessage(message.jsify(), _frameUrl.origin.toJS);
  }

  void _load(String name) {
    if (mounted) setState(() => _phase = _Phase.loading);
    _armWatchdog();
    _send({'type': 'load', 'modelName': name});
  }

  /// No sign of life from the player in time → offer a retry.
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 25), () {
      if (mounted && _phase == _Phase.loading) {
        setState(() => _phase = _Phase.failed);
      }
    });
  }

  void _handleMessage(web.MessageEvent e) {
    // Only this iframe's page, from its own origin.
    if (e.origin != _frameUrl.origin) return;
    final frameWindow = _frame?.contentWindow;
    final source = e.source;
    if (frameWindow == null ||
        source == null ||
        !source.strictEquals(frameWindow).toDart) {
      return;
    }
    final data = e.data.dartify();
    if (data is! Map || data['source'] != 'moco-live-player') return;
    final payload = data['payload'] is Map ? data['payload'] as Map : const {};
    if (!mounted) return;

    switch (data['event']) {
      case 'mounted' || 'ready' || 'play':
        _watchdog?.cancel();
        if (_phase != _Phase.ready) setState(() => _phase = _Phase.ready);
      case 'error':
        _onError(payload['type'] as String?, payload['fatal'] == true);
    }
  }

  void _onError(String? type, bool fatal) {
    switch (type) {
      case 'offline':
        _watchdog?.cancel();
        setState(() => _phase = _Phase.offline);
      case 'unavailable':
        _watchdog?.cancel();
        setState(() => _phase = _Phase.unavailable);
      case 'fullscreen':
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Fullscreen isn’t available here.')),
        );
      case 'player':
        _watchdog?.cancel();
        setState(() => _phase = _Phase.failed);
      default:
        // Playback trouble: the player retries by itself. Only a fatal one
        // needs the viewer.
        if (fatal) setState(() => _phase = _Phase.interrupted);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        HtmlElementView(viewType: _viewType),
        if (_phase == _Phase.loading)
          const IgnorePointer(
            child: Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          ),
        if (_phase.index > _Phase.ready.index) _overlay(),
      ],
    );
  }

  Widget _overlay() {
    final (title, message, retry) = switch (_phase) {
      _Phase.offline => (
        '${widget.modelName} is offline',
        'This show has ended for now.',
        false,
      ),
      _Phase.unavailable => (
        'Show unavailable',
        'This model is in a private show or not available right now.',
        true,
      ),
      _Phase.interrupted => (
        'Stream interrupted',
        'The connection to the stream dropped.',
        true,
      ),
      _ => (
        'The live player couldn’t load',
        'Check your connection and try again.',
        true,
      ),
    };
    return ColoredBox(
      key: ValueKey('live_player_state_${_phase.name}'),
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (retry)
                    OutlinedButton(
                      key: const Key('live_player_retry'),
                      onPressed: () => _load(widget.modelName),
                      child: const Text('Try again'),
                    ),
                  if (widget.onExit != null)
                    FilledButton(
                      key: const Key('live_player_exit'),
                      style: FilledButton.styleFrom(
                        backgroundColor: MocoColors.accentPrimary,
                      ),
                      onPressed: widget.onExit,
                      child: const Text('Back to Live'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
