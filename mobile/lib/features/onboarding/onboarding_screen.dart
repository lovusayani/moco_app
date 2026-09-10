import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';

class _Page {
  const _Page({required this.title, required this.body, required this.icon});
  final String title;
  final String body;
  final IconData icon;
}

/// Three-page onboarding carousel.
///
/// Deliberately makes no network call: onboarding runs before the user has a
/// session, and completion is a local device fact, so it is persisted to
/// SharedPreferences and nothing else.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  static const _pages = <_Page>[
    _Page(
      icon: Icons.record_voice_over_rounded,
      title: 'Someone to talk to,\nany time',
      body: 'Real people ready to listen — in English, Hindi and Telugu. No pressure, no judgement.',
    ),
    _Page(
      icon: Icons.bolt_rounded,
      title: 'Pay by the minute',
      body: 'Buy coins and spend them only while you are talking. No subscription, no lock-in.',
    ),
    _Page(
      icon: Icons.favorite_rounded,
      title: 'Your first minute\nis on us',
      body: 'Start your first call free. Become a listener yourself later and earn for your time.',
    ),
  ];

  bool get _isLast => _index == _pages.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await ref.read(authActionsProvider).completeOnboarding();
    if (mounted) context.go(Routes.login);
  }

  void _next() {
    if (_isLast) {
      _finish();
    } else {
      _controller.nextPage(
        duration: MocoDuration.onboarding,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MocoBackground(
        ambience: MocoAmbience.rich,
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MocoSpacing.md,
                    vertical: MocoSpacing.sm,
                  ),
                  child: TextButton(
                    key: const Key('onboarding_skip'),
                    onPressed: _finish,
                    child: const Text(
                      'Skip',
                      style: TextStyle(color: MocoColors.textMuted),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _OnboardingPage(page: _pages[i]),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (i) {
                  final active = i == _index;
                  return AnimatedContainer(
                    duration: MocoDuration.tab,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 22 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: active
                          ? MocoColors.accentPrimary
                          : MocoColors.borderStrong,
                      borderRadius: BorderRadius.circular(MocoRadius.pill),
                    ),
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.all(MocoSpacing.screenPadding),
                child: MocoPrimaryButton(
                  key: const Key('onboarding_cta'),
                  label: _isLast ? 'Get started' : 'Next',
                  onPressed: _next,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({required this.page});

  final _Page page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 116,
            height: 116,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: MocoColors.accentGradient,
              boxShadow: [
                BoxShadow(
                  color: MocoColors.accentPrimary.withValues(alpha: 0.36),
                  blurRadius: 44,
                ),
              ],
            ),
            child: Icon(page.icon, size: 50, color: MocoColors.textOnAccent),
          ),
          const SizedBox(height: MocoSpacing.xxl),
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: MocoColors.textPrimary,
              fontSize: 29,
              fontWeight: FontWeight.w700,
              height: 1.25,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: MocoSpacing.lg),
          Text(
            page.body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: MocoColors.textSecondary,
              fontSize: 15.5,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}
