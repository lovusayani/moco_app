import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/theme/moco_theme.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';
import 'app_settings_controller.dart';
import '../feed/feed_preferences.dart';
import '../../core/routing/app_router.dart';
import '../../core/routing/pop_or_go.dart';

/// App Settings — display-only preferences (theme, font, Discovery layout)
/// plus a placeholder for the still-deferred app icon picker. Nothing here
/// is a backend concept: every value is read from and written straight to
/// [AppPreferences], the same local store `activeRole`/`onboardingComplete`
/// already use.
class AppSettingsScreen extends ConsumerWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('App settings'),
        leading: deepLinkBackButton(context, Routes.profile),
      ),
      body: MocoBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(MocoSpacing.screenPadding),
            children: const [
              MocoSectionHeader(title: 'Appearance'),
              SizedBox(height: MocoSpacing.md),
              _ThemeSection(),
              SizedBox(height: MocoSpacing.xl),
              MocoSectionHeader(title: 'Typeface'),
              SizedBox(height: MocoSpacing.md),
              _FontSection(),
              SizedBox(height: MocoSpacing.xl),
              MocoSectionHeader(title: 'App icon'),
              SizedBox(height: MocoSpacing.md),
              _AppIconSection(),
              SizedBox(height: MocoSpacing.xl),
              MocoSectionHeader(title: 'Discovery layout'),
              SizedBox(height: MocoSpacing.md),
              _DiscoveryLayoutSection(),
              SizedBox(height: MocoSpacing.xl),
              MocoSectionHeader(title: 'Feed'),
              SizedBox(height: MocoSpacing.md),
              _FeedSection(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeSection extends ConsumerWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final controller = ref.read(themeModeProvider.notifier);

    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
      child: Column(
        children: [
          _OptionRow(
            testKey: 'app_settings_theme_light',
            icon: Icons.light_mode_outlined,
            label: 'Light',
            selected: mode == ThemeMode.light,
            onTap: () => controller.setMode(ThemeMode.light),
          ),
          const _RowDivider(),
          _OptionRow(
            testKey: 'app_settings_theme_dark',
            icon: Icons.dark_mode_outlined,
            label: 'Dark',
            selected: mode == ThemeMode.dark,
            onTap: () => controller.setMode(ThemeMode.dark),
          ),
          const _RowDivider(),
          _OptionRow(
            testKey: 'app_settings_theme_system',
            icon: Icons.brightness_auto_outlined,
            label: 'System',
            selected: mode == ThemeMode.system,
            onTap: () => controller.setMode(ThemeMode.system),
          ),
        ],
      ),
    );
  }
}

class _FontSection extends ConsumerWidget {
  const _FontSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(fontChoiceProvider);
    final controller = ref.read(fontChoiceProvider.notifier);

    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
      child: Column(
        children: [
          _OptionRow(
            testKey: 'app_settings_font_inter',
            icon: Icons.text_fields_rounded,
            label: 'Moco Default (Inter)',
            selected: choice == MocoFontChoice.inter,
            onTap: () => controller.setChoice(MocoFontChoice.inter),
          ),
          const _RowDivider(),
          _OptionRow(
            testKey: 'app_settings_font_system',
            icon: Icons.phone_iphone_rounded,
            label: 'System default',
            selected: choice == MocoFontChoice.system,
            onTap: () => controller.setChoice(MocoFontChoice.system),
          ),
        ],
      ),
    );
  }
}

/// Deferred: the row exists so users know the setting is coming, but no
/// dynamic icon-switching is wired up — Android's `LauncherActivity-alias`
/// approach (or iOS's alternate icons) is real platform-config work for a
/// later phase, not something to fake with a client-only flag.
class _AppIconSection extends StatelessWidget {
  const _AppIconSection();

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      child: Row(
        children: [
          Icon(Icons.apps_rounded, color: MocoColors.textMuted, size: 20),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'App icon',
                  style: TextStyle(color: MocoColors.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Coming in a later update',
                  style: TextStyle(color: MocoColors.textMuted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          Container(
            key: const Key('app_settings_icon_coming_soon'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: MocoColors.surfaceGlass,
              borderRadius: BorderRadius.circular(MocoRadius.pill),
              border: Border.all(color: MocoColors.borderSubtle),
            ),
            child: Text(
              'Soon',
              style: TextStyle(color: MocoColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscoveryLayoutSection extends ConsumerWidget {
  const _DiscoveryLayoutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = ref.watch(discoveryColumnsProvider);
    final controller = ref.read(discoveryColumnsProvider.notifier);

    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.sm),
      child: Column(
        children: [
          _OptionRow(
            testKey: 'app_settings_discovery_1col',
            icon: Icons.view_agenda_outlined,
            label: '1 profile per row',
            description: 'Large cards',
            selected: columns == 1,
            onTap: () => controller.setColumns(1),
          ),
          const _RowDivider(),
          _OptionRow(
            testKey: 'app_settings_discovery_2col',
            icon: Icons.view_column_outlined,
            label: '2 profiles per row',
            description: 'Medium cards',
            selected: columns == 2,
            onTap: () => controller.setColumns(2),
          ),
          const _RowDivider(),
          _OptionRow(
            testKey: 'app_settings_discovery_3col',
            icon: Icons.grid_view_rounded,
            label: '3 profiles per row',
            description: 'Compact cards',
            selected: columns == 3,
            onTap: () => controller.setColumns(3),
          ),
        ],
      ),
    );
  }
}

class _FeedSection extends ConsumerWidget {
  const _FeedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(feedAutoScrollProvider);

    return MocoGlassCard(
      padding: const EdgeInsets.symmetric(vertical: MocoSpacing.xs),
      // Its own Material so the tile's ink is not hidden by the glass card.
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile.adaptive(
          key: const Key('app_settings_feed_auto_scroll'),
          value: enabled,
          onChanged: (value) =>
              ref.read(feedAutoScrollProvider.notifier).setEnabled(value),
          activeTrackColor: MocoColors.accentPrimary,
          secondary: Icon(
            Icons.swipe_up_alt_rounded,
            color: enabled ? MocoColors.accentSoft : MocoColors.textSecondary,
          ),
          title: Text(
            'Feed auto-scroll',
            style: TextStyle(
              color: MocoColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            'Moves to the next post when a video ends, or after 5 seconds on '
            'a photo. Touching the feed pauses it until you come back.',
            style: TextStyle(color: MocoColors.textSecondary, fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.testKey,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.description,
  });

  final String testKey;
  final IconData icon;
  final String label;
  final String? description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key(testKey),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MocoSpacing.lg,
            vertical: MocoSpacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, color: selected ? MocoColors.accentPrimary : MocoColors.textMuted, size: 20),
              const SizedBox(width: MocoSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: selected ? MocoColors.textPrimary : MocoColors.textSecondary,
                        fontSize: 14.5,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          description!,
                          style: TextStyle(color: MocoColors.textMuted, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded, color: MocoColors.accentPrimary, size: 20)
              else
                Icon(Icons.circle_outlined, color: MocoColors.borderStrong, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: MocoSpacing.lg,
      endIndent: MocoSpacing.lg,
      color: MocoColors.borderSubtle,
    );
  }
}
