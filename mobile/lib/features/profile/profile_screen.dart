import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/user.dart';
import 'profile_controller.dart';

/// Own Profile.
///
/// One account, one shell: this screen does not navigate to a separate
/// listener app. When the account is `both` or `listener`, a segmented
/// control switches which sections render (caller vs listener), purely a
/// display choice — [ActiveRoleController] never calls the backend.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final activeRole = ref.watch(activeRoleProvider);

    if (user == null) {
      // Never actually reachable — the router keeps this screen behind
      // authentication — but a null-safe fallback is cheaper than a bang.
      return const SizedBox.shrink();
    }

    final showingListener = activeRole == ActiveRoleController.listener && user.canBeListener;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          MocoSpacing.screenPadding,
          MocoSpacing.lg,
          MocoSpacing.screenPadding,
          MocoSpacing.xxl,
        ),
        children: [
          const Text(
            'Profile',
            style: TextStyle(
              color: MocoColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: MocoSpacing.lg),
          _IdentityCard(user: user),
          if (user.canBeListener) ...[
            const SizedBox(height: MocoSpacing.lg),
            _RoleSwitch(activeRole: activeRole),
          ],
          const SizedBox(height: MocoSpacing.xl),
          if (showingListener)
            _ListenerSections(user: user)
          else
            _CallerSections(user: user),
          const SizedBox(height: MocoSpacing.xl),
          MocoSectionHeader(title: 'Account'),
          const SizedBox(height: MocoSpacing.md),
          _NavRow(
            key: const Key('profile_settings_row'),
            icon: Icons.settings_outlined,
            label: 'Account settings',
            onTap: () => context.push(Routes.accountSettings),
          ),
          if (!user.canBeListener) ...[
            const SizedBox(height: MocoSpacing.sm),
            _NavRow(
              key: const Key('profile_become_listener_row'),
              icon: Icons.mic_outlined,
              label: 'Apply to become a listener',
              onTap: () => context.push(Routes.editProfile, extra: true),
            ),
          ],
        ],
      ),
    );
  }
}

class _IdentityCard extends ConsumerWidget {
  const _IdentityCard({required this.user});

  final MocoUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MocoGlassCard(
      child: Row(
        children: [
          MocoAvatar(
            name: user.displayName ?? user.phone,
            imageUrl: user.avatarUrl,
            size: 64,
          ),
          const SizedBox(width: MocoSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (user.displayName?.trim().isNotEmpty ?? false)
                      ? user.displayName!.trim()
                      : 'Moco user',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user.phone,
                  style: const TextStyle(color: MocoColors.textMuted, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('profile_edit_button'),
            onPressed: () => context.push(Routes.editProfile),
            icon: const Icon(Icons.edit_outlined, color: MocoColors.textSecondary),
            tooltip: 'Edit profile',
          ),
        ],
      ),
    );
  }
}

class _RoleSwitch extends ConsumerWidget {
  const _RoleSwitch({required this.activeRole});

  final String activeRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(activeRoleProvider.notifier);

    return Container(
      key: const Key('profile_role_switch'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: MocoColors.surfaceGlass,
        borderRadius: BorderRadius.circular(MocoRadius.pill),
        border: Border.all(color: MocoColors.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: _RoleSwitchSegment(
              key: const Key('profile_role_caller'),
              label: 'Calling',
              selected: activeRole == ActiveRoleController.caller,
              onTap: () => controller.setRole(ActiveRoleController.caller),
            ),
          ),
          Expanded(
            child: _RoleSwitchSegment(
              key: const Key('profile_role_listener'),
              label: 'Listening',
              selected: activeRole == ActiveRoleController.listener,
              onTap: () => controller.setRole(ActiveRoleController.listener),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleSwitchSegment extends StatelessWidget {
  const _RoleSwitchSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? MocoColors.accentPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(MocoRadius.pill),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? MocoColors.textOnAccent : MocoColors.textSecondary,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CallerSections extends StatelessWidget {
  const _CallerSections({required this.user});

  final MocoUser user;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MocoSectionHeader(title: 'Wallet'),
        const SizedBox(height: MocoSpacing.md),
        _NavRow(
          key: const Key('profile_wallet_row'),
          icon: Icons.account_balance_wallet_outlined,
          label: 'Wallet & top-up',
          trailing: '${user.coinBalance} coins',
          onTap: () => context.push(Routes.wallet),
        ),
        const SizedBox(height: MocoSpacing.sm),
        _NavRow(
          key: const Key('profile_coin_ledger_row'),
          icon: Icons.receipt_long_outlined,
          label: 'Coin ledger',
          onTap: () => context.push(Routes.coinLedger),
        ),
      ],
    );
  }
}

class _ListenerSections extends ConsumerStatefulWidget {
  const _ListenerSections({required this.user});

  final MocoUser user;

  @override
  ConsumerState<_ListenerSections> createState() => _ListenerSectionsState();
}

class _ListenerSectionsState extends ConsumerState<_ListenerSections> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(profileControllerProvider.notifier).loadEarnings());
  }

  @override
  Widget build(BuildContext context) {
    final listener = widget.user.listener;
    final state = ref.watch(profileControllerProvider);
    final controller = ref.read(profileControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MocoSectionHeader(title: 'Listener status'),
        const SizedBox(height: MocoSpacing.md),
        _KycStatusCard(kycStatus: listener?.kycStatus ?? 'unsubmitted'),
        if (listener?.isApproved ?? false) ...[
          const SizedBox(height: MocoSpacing.md),
          _AvailabilityCard(
            key: const Key('profile_availability_card'),
            isOnline: listener?.isOnline ?? false,
            isBusy: state.isTogglingAvailability,
            error: state.availabilityError,
            onChanged: controller.setAvailability,
          ),
        ],
        const SizedBox(height: MocoSpacing.xl),
        MocoSectionHeader(title: 'Earnings'),
        const SizedBox(height: MocoSpacing.md),
        if (state.isLoadingEarnings && state.earnings == null)
          const MocoSkeleton(height: 90)
        else if (state.earningsError != null && state.earnings == null)
          Text(
            ApiErrorMapper.from(state.earningsError!).message,
            style: const TextStyle(color: MocoColors.danger, fontSize: 13),
          )
        else if (state.earnings != null)
          _EarningsCard(earnings: state.earnings!),
        const SizedBox(height: MocoSpacing.sm),
        _NavRow(
          key: const Key('profile_earnings_ledger_row'),
          icon: Icons.receipt_long_outlined,
          label: 'Earnings history',
          onTap: () => context.push(Routes.earningsLedger),
        ),
      ],
    );
  }
}

class _KycStatusCard extends StatelessWidget {
  const _KycStatusCard({required this.kycStatus});

  final String kycStatus;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (kycStatus) {
      'approved' => ('Verified listener', MocoColors.success, Icons.verified_rounded),
      'pending' => ('Verification pending', MocoColors.warning, Icons.hourglass_top_rounded),
      'rejected' => ('Verification rejected', MocoColors.danger, Icons.error_outline_rounded),
      _ => ('Not yet verified', MocoColors.textMuted, Icons.info_outline_rounded),
    };

    return MocoGlassCard(
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 14.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailabilityCard extends StatelessWidget {
  const _AvailabilityCard({
    super.key,
    required this.isOnline,
    required this.isBusy,
    required this.onChanged,
    this.error,
  });

  final bool isOnline;
  final bool isBusy;
  final ApiException? error;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isOnline ? 'You are online' : 'You are offline',
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                key: const Key('profile_availability_switch'),
                value: isOnline,
                onChanged: isBusy ? null : onChanged,
                activeThumbColor: MocoColors.accentPrimary,
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: MocoSpacing.sm),
            Text(
              ApiErrorMapper.from(error!).message,
              style: const TextStyle(color: MocoColors.danger, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _EarningsCard extends StatelessWidget {
  const _EarningsCard({required this.earnings});

  final dynamic earnings;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      child: Row(
        children: [
          _EarningsFigure(label: 'Balance', value: '₹${earnings.balance}'),
          _EarningsFigure(label: 'Today', value: '₹${earnings.today}'),
          _EarningsFigure(label: 'Lifetime', value: '₹${earnings.lifetime}'),
        ],
      ),
    );
  }
}

class _EarningsFigure extends StatelessWidget {
  const _EarningsFigure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: MocoColors.coinAccent,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: MocoColors.textMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: MocoSpacing.lg, vertical: MocoSpacing.md),
      child: Row(
        children: [
          Icon(icon, color: MocoColors.accentSoft, size: 20),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) ...[
            Text(trailing!, style: const TextStyle(color: MocoColors.textMuted, fontSize: 13)),
            const SizedBox(width: MocoSpacing.sm),
          ],
          const Icon(Icons.chevron_right_rounded, color: MocoColors.textMuted),
        ],
      ),
    );
  }
}
