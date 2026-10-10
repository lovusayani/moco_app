import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../core/errors/api_exception.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_app_frame.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';
import '../../shared/models/live.dart';
import 'live_controller.dart';
import 'platform/live_platform.dart';
import 'widgets/live_model_card.dart';

/// Internal Moco Live player for one provider model: the official Stripchat
/// player (see live_platform_web.dart) on a centred, embedded 9:16 stage,
/// with the model's details as glass overlays the viewer can hide. Only the
/// player's own fullscreen control gives the stream the whole viewport.
/// Nothing here creates a Moco account or profile for the model.
class LivePlayerScreen extends ConsumerWidget {
  const LivePlayerScreen({super.key, required this.username, this.model});

  final String username;

  /// Passed from the listing; null after a page reload (details then show
  /// only the username).
  final LiveModel? model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(liveConfigProvider);
    final selected = ref.watch(liveSelectedModelProvider);
    final m = model ?? (selected?.username == username ? selected : null);

    return Scaffold(
      backgroundColor: Colors.black,
      body: config.when(
        loading: () => const MocoBackground(
          child: Center(child: CircularProgressIndicator(strokeWidth: 2.2)),
        ),
        error: (e, _) => MocoBackground(
          child: SafeArea(
            child: MocoErrorState(
              title: 'Live could not load',
              message: e is ApiException ? e.message : 'Please try again.',
              onRetry: () => ref.invalidate(liveConfigProvider),
            ),
          ),
        ),
        data: (cfg) {
          // The 18+ gate and the on/off switch apply here too — a direct
          // link cannot skip them.
          if (!cfg.enabled ||
              (cfg.requireAgeConfirmation &&
                  !ref.watch(liveAgeConfirmedProvider))) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go(Routes.live);
            });
            return const SizedBox.shrink();
          }
          return _ImmersivePlayer(username: username, model: m, config: cfg);
        },
      ),
    );
  }
}

/// Below this width the stage keeps a phone-sized margin; above it, a wider
/// one. Either way it is a centred 9:16 stage on a dark backdrop — never a
/// stretched landscape block, and never the whole viewport until the viewer
/// asks for fullscreen.
const double _phoneBelow = 600;

class _ImmersivePlayer extends StatefulWidget {
  const _ImmersivePlayer({
    required this.username,
    required this.model,
    required this.config,
  });

  final String username;
  final LiveModel? model;
  final LiveConfig config;

  @override
  State<_ImmersivePlayer> createState() => _ImmersivePlayerState();
}

class _ImmersivePlayerState extends State<_ImmersivePlayer> {
  bool _overlays = true;

  /// The player is in fullscreen (its own control): the stage takes the
  /// whole viewport, with no page chrome or overlays, until it exits.
  bool _fullscreen = false;

  void _onFullscreenChanged(bool value) {
    if (mounted && value != _fullscreen) setState(() => _fullscreen = value);
  }

  @override
  void initState() {
    super.initState();
    // The stage and its backdrop want the whole window on desktop, not the
    // app's phone-width column.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => MocoAppFrame.fullBleedRequests.value++,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => MocoAppFrame.fullBleedRequests.value--,
    );
    super.dispose();
  }

  void _back() => context.canPop() ? context.pop() : context.go(Routes.live);

  @override
  Widget build(BuildContext context) {
    final player = widget.config.player;
    final fallback = _PlayerFallback(
      key: const Key('live_player_fallback'),
      imageUrl: widget.model?.imageUrl,
    );
    final media = player == null
        ? fallback
        : stripchatPlayerView(
            modelName: widget.username,
            config: player,
            fallback: fallback,
            onExit: _back,
            onFullscreenChanged: _onFullscreenChanged,
          );

    return LayoutBuilder(
      builder: (context, c) {
        final fullBleed = _fullscreen;
        var w = c.maxWidth;
        var h = c.maxHeight;
        if (!fullBleed) {
          // Tallest 9:16 stage that fits with a margin all round (and clear
          // of the phone's safe areas).
          final safe = MediaQuery.paddingOf(context);
          final margin = c.maxWidth < _phoneBelow
              ? MocoSpacing.lg
              : MocoSpacing.xl + MocoSpacing.lg;
          h = c.maxHeight - safe.vertical - margin * 2;
          w = h * 9 / 16;
          if (w > c.maxWidth - margin * 2) {
            w = c.maxWidth - margin * 2;
            h = w * 16 / 9;
          }
        }
        final radius = BorderRadius.circular(fullBleed ? 0 : MocoRadius.xl);

        return Stack(
          fit: StackFit.expand,
          children: [
            const _Backdrop(),
            Center(
              child: SizedBox(
                key: const Key('live_player_stage'),
                width: w,
                height: h,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: fullBleed
                        ? null
                        : [
                            BoxShadow(
                              color: MocoColors.accentPrimary.withValues(
                                alpha: 0.18,
                              ),
                              blurRadius: 60,
                              spreadRadius: 2,
                            ),
                            const BoxShadow(
                              color: Colors.black54,
                              blurRadius: 30,
                              offset: Offset(0, 16),
                            ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        media,
                        if (!fullBleed)
                          _StageOverlays(
                            username: widget.username,
                            model: widget.model,
                            visible: _overlays,
                            insets: EdgeInsets.zero,
                            onBack: _back,
                            onToggle: () =>
                                setState(() => _overlays = !_overlays),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Dark, softly lit surround for the stage on wider screens. Plain
/// gradients only: the stream itself is a browser frame, which Flutter
/// cannot blur, so nothing here pretends to.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 1.1,
          colors: [
            MocoColors.accentDeep.withValues(alpha: 0.55),
            const Color(0xFF0B060A),
          ],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.9, 0.9),
            radius: 0.9,
            colors: [
              MocoColors.accentPrimary.withValues(alpha: 0.12),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything drawn on top of the stream.
///
/// Placement keeps clear of the provider player's own controls (volume and
/// fullscreen at its top right, play in the centre): back at the top left,
/// the overlay toggle floating on the right edge, details at the bottom.
/// Back and the toggle always stay visible, so hiding the details never
/// strands the viewer; hiding never touches the player itself.
///
/// On the web the stream is a browser frame, which would otherwise receive
/// the clicks meant for anything drawn over it; PointerInterceptor gives the
/// overlay its clicks there (and stops intercepting while the details are
/// hidden, so the stream underneath is fully usable).
class _StageOverlays extends StatelessWidget {
  const _StageOverlays({
    required this.username,
    required this.model,
    required this.visible,
    required this.insets,
    required this.onBack,
    required this.onToggle,
  });

  final String username;
  final LiveModel? model;
  final bool visible;
  final EdgeInsets insets;
  final VoidCallback onBack;
  final VoidCallback onToggle;

  static const _motion = Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Bottom scrim for readability; fades with the details.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: _motion,
            curve: Curves.easeOutCubic,
            child: const Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: 0.42,
                widthFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xB3000000)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: insets.top + MocoSpacing.md,
          left: MocoSpacing.md,
          child: PointerInterceptor(
            child: _GlassCircleButton(
              key: const Key('live_player_back'),
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back to Live',
              onPressed: onBack,
            ),
          ),
        ),
        Positioned(
          right: MocoSpacing.md,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: const Alignment(0, -0.18),
            child: PointerInterceptor(
              child: _GlassCircleButton(
                key: const Key('live_overlay_toggle'),
                icon: visible
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                tooltip: visible ? 'Hide details' : 'Show details',
                active: !visible,
                onPressed: onToggle,
              ),
            ),
          ),
        ),
        Positioned(
          left: MocoSpacing.md,
          right: MocoSpacing.md,
          bottom: insets.bottom + MocoSpacing.md,
          child: PointerInterceptor(
            intercepting: visible,
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                key: const Key('live_player_details_visibility'),
                opacity: visible ? 1 : 0,
                duration: _motion,
                curve: Curves.easeOutCubic,
                child: AnimatedSlide(
                  offset: visible ? Offset.zero : const Offset(0, 0.12),
                  duration: _motion,
                  curve: Curves.easeOutCubic,
                  child: _DetailsPanel(username: username, model: model),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dark glass over the stream: a translucent tinted fill, hairline border and
/// soft shadow (a backdrop blur cannot reach into the browser frame below).
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1C0F18).withValues(alpha: 0.72),
            MocoColors.accentDeep.withValues(alpha: 0.55),
          ],
        ),
        borderRadius: BorderRadius.circular(MocoRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(MocoSpacing.md + 2),
        child: child,
      ),
    );
  }
}

class _GlassCircleButton extends StatefulWidget {
  const _GlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool active;

  @override
  State<_GlassCircleButton> createState() => _GlassCircleButtonState();
}

class _GlassCircleButtonState extends State<_GlassCircleButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final button = GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _down ? 0.9 : 1,
        duration: MocoDuration.press,
        curve: Curves.easeOutBack,
        child: AnimatedContainer(
          duration: MocoDuration.tab,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? MocoColors.accentPrimary.withValues(alpha: 0.34)
                : Colors.black.withValues(alpha: 0.42),
            border: Border.all(
              color: active
                  ? MocoColors.accentPrimary.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.18),
            ),
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 14)],
          ),
          child: Icon(widget.icon, color: Colors.white, size: 20),
        ),
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: widget.tooltip == null
          ? button
          : Tooltip(message: widget.tooltip!, child: button),
    );
  }
}

/// Bottom-left details: who is live, how many watch, where from, tags, and
/// the external-provider note (kept, but as a small footnote).
class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.username, required this.model});

  final String username;
  final LiveModel? model;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final country = m?.country;
    final flag = countryFlag(country);
    final facts = <Widget>[
      if (m != null)
        _Fact(
          icon: Icons.visibility_rounded,
          text: '${compactCount(m.viewers)} watching',
        ),
      if (flag != null && country != null)
        _Fact(text: '$flag ${country.toUpperCase()}'),
      if (m != null && m.languages.isNotEmpty)
        _Fact(
          icon: Icons.translate_rounded,
          text: m.languages.take(3).map((l) => l.toUpperCase()).join(' · '),
        ),
    ];

    return Align(
      alignment: Alignment.bottomLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: _GlassPanel(
          child: Column(
            key: const Key('live_player_details'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const LiveBadge(),
                  const SizedBox(width: MocoSpacing.sm),
                  Flexible(
                    child: Text(
                      username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                      ),
                    ),
                  ),
                  if (m != null && m.isHd) ...[
                    const SizedBox(width: MocoSpacing.sm),
                    const _HdBadge(),
                  ],
                ],
              ),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: MocoSpacing.sm),
                Wrap(spacing: MocoSpacing.md, runSpacing: 6, children: facts),
              ],
              if (m != null && m.tags.isNotEmpty) ...[
                const SizedBox(height: MocoSpacing.sm + 2),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in m.tags.take(5))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(MocoRadius.pill),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Text(
                          '#${t.split('/').last}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: MocoSpacing.sm + 2),
              Text(
                'External stream · Moco doesn’t host this content.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HdBadge extends StatelessWidget {
  const _HdBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: const Text(
        'HD',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.88),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Shown when the provider's player script is not configured (or off the
/// web): the model's provider image with an honest note — no stream is
/// faked and no direct stream URL is used.
class _PlayerFallback extends StatelessWidget {
  const _PlayerFallback({super.key, required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 0.35, child: LiveImage(url: imageUrl)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(MocoSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white,
                  size: 34,
                ),
                const SizedBox(height: MocoSpacing.sm),
                const Text(
                  'The live player isn’t available yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Streams will play here once the provider player is configured.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
