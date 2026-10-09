import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/live.dart';
import 'live_controller.dart';
import 'platform/live_platform.dart';
import 'widgets/live_model_card.dart';

/// Internal Moco Live player for one provider model: the official Stripchat
/// player (see live_platform_web.dart) with the provider-backed details
/// around it. Nothing here creates a Moco account or profile for the model.
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
      body: MocoBackground(
        child: SafeArea(
          child: config.when(
            loading: () => const Center(
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            error: (e, _) => MocoErrorState(
              title: 'Live could not load',
              message: e is ApiException ? e.message : 'Please try again.',
              onRetry: () => ref.invalidate(liveConfigProvider),
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
              return _PlayerBody(username: username, model: m, config: cfg);
            },
          ),
        ),
      ),
    );
  }
}

class _PlayerBody extends StatelessWidget {
  const _PlayerBody({
    required this.username,
    required this.model,
    required this.config,
  });

  final String username;
  final LiveModel? model;
  final LiveConfig config;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final player = config.player;
    final fallback = _PlayerFallback(
      key: const Key('live_player_fallback'),
      imageUrl: m?.imageUrl,
    );
    final flag = countryFlag(m?.country);

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final stage = ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: Colors.black,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: player == null
                  ? fallback
                  : stripchatPlayerView(
                      modelName: username,
                      config: player,
                      fallback: fallback,
                      onExit: () => context.canPop()
                          ? context.pop()
                          : context.go(Routes.live),
                    ),
            ),
          ),
        );
        final details = Column(
          key: const Key('live_player_details'),
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
                    style: TextStyle(
                      color: MocoColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (m != null && m.isHd) ...[
                  const SizedBox(width: MocoSpacing.sm),
                  MocoChip(label: 'HD', onTap: null),
                ],
              ],
            ),
            if (m != null) ...[
              const SizedBox(height: MocoSpacing.md),
              Wrap(
                spacing: MocoSpacing.md,
                runSpacing: MocoSpacing.sm,
                children: [
                  _Fact(
                    icon: Icons.visibility_rounded,
                    text: '${compactCount(m.viewers)} watching',
                  ),
                  if (flag != null)
                    _Fact(text: '$flag  ${m.country!.toUpperCase()}'),
                  if (m.languages.isNotEmpty)
                    _Fact(
                      icon: Icons.translate_rounded,
                      text: m.languages.map((l) => l.toUpperCase()).join(' · '),
                    ),
                ],
              ),
              if (m.tags.isNotEmpty) ...[
                const SizedBox(height: MocoSpacing.md),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in m.tags.take(8))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: MocoColors.surfaceGlass,
                          borderRadius: BorderRadius.circular(MocoRadius.pill),
                          border: Border.all(color: MocoColors.borderSubtle),
                        ),
                        child: Text(
                          '#${t.split('/').last}',
                          style: TextStyle(
                            color: MocoColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: MocoSpacing.lg),
            Text(
              'Streamed by an external provider. Moco doesn’t host this content.',
              style: TextStyle(color: MocoColors.textMuted, fontSize: 11.5),
            ),
          ],
        );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MocoSpacing.sm,
                MocoSpacing.sm,
                MocoSpacing.sm,
                0,
              ),
              child: Row(
                children: [
                  MocoIconButton(
                    key: const Key('live_player_back'),
                    icon: Icons.arrow_back_rounded,
                    size: 40,
                    onPressed: () => context.canPop()
                        ? context.pop()
                        : context.go(Routes.live),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MocoSpacing.lg),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 7, child: stage),
                              const SizedBox(width: MocoSpacing.xl),
                              Expanded(flex: 4, child: details),
                            ],
                          )
                        : Column(
                            children: [
                              stage,
                              const SizedBox(height: MocoSpacing.lg),
                              details,
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
          Icon(icon, size: 15, color: MocoColors.textMuted),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(color: MocoColors.textSecondary, fontSize: 13),
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
