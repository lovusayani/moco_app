import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/auth/auth_state.dart';
import '../../core/errors/api_exception.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/providers.dart';
import '../../core/routing/app_router.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_avatar.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/user.dart';
import '../listener_application/listener_application_controller.dart';
import '../listener_application/listener_application_screen.dart';
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

    final showingListener =
        activeRole == ActiveRoleController.listener && user.canBeListener;

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
          Text(
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
          const SizedBox(height: MocoSpacing.sm),
          _NavRow(
            key: const Key('profile_app_settings_row'),
            icon: Icons.tune_rounded,
            label: 'App settings',
            onTap: () => context.push(Routes.appSettings),
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

class _IdentityCard extends ConsumerStatefulWidget {
  const _IdentityCard({required this.user});

  final MocoUser user;

  @override
  ConsumerState<_IdentityCard> createState() => _IdentityCardState();
}

class _IdentityCardState extends ConsumerState<_IdentityCard> {
  bool _uploading = false;
  Uint8List? _preview;

  Future<void> _pickAndUploadAvatar() async {
    if (_uploading) return;
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    if (file == null) return;

    final mimeType = listenerPhotoMimeType(file.name);
    if (mimeType == null) {
      _showError('Only JPEG, PNG or WebP images can be used.');
      return;
    }

    final bytes = await file.readAsBytes();
    setState(() {
      _uploading = true;
      _preview = bytes;
    });

    try {
      final api = ref.read(usersApiProvider);
      final auth = await api.requestAvatarUploadUrl(mimeType);

      if (bytes.length > auth.maxBytes) {
        final mb = (auth.maxBytes / (1024 * 1024)).round();
        _showError('That image is too large (max $mb MB).');
        setState(() {
          _uploading = false;
          _preview = null;
        });
        return;
      }

      await dioPhotoUploader(
        uploadUrl: auth.uploadUrl,
        token: auth.token,
        mimeType: mimeType,
        bytes: bytes,
        onProgress: (_) {},
      );

      final user = await api.registerAvatar(auth.path);
      final controller = ref.read(authActionsProvider);
      controller.value = controller.value.copyWith(
        user: user,
        status: AuthState.statusForUser(user),
      );
    } on ApiException catch (e) {
      _showError(ApiErrorMapper.from(e).message);
    } on DioException catch (e) {
      _showError(ApiErrorMapper.fromDioException(e).message);
    }

    if (mounted) setState(() { _uploading = false; _preview = null; });
  }

  void _showError(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return MocoGlassCard(
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (_preview != null)
                ClipOval(
                  child: Image.memory(
                    _preview!,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                )
              else
                MocoAvatar(
                  name: user.displayName ?? user.contactLabel,
                  imageUrl: user.avatarUrl,
                  size: 64,
                ),
              Positioned(
                bottom: -2,
                right: -2,
                child: _AvatarCameraButton(
                  key: const Key('profile_avatar_camera'),
                  uploading: _uploading,
                  onTap: _pickAndUploadAvatar,
                ),
              ),
            ],
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
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user.contactLabel,
                  style: TextStyle(color: MocoColors.textMuted, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('profile_edit_button'),
            onPressed: () => context.push(Routes.editProfile),
            icon: Icon(Icons.edit_outlined, color: MocoColors.textSecondary),
            tooltip: 'Edit profile',
          ),
        ],
      ),
    );
  }
}

const _cameraPurple = Color(0xFF8E5CF7);

class _AvatarCameraButton extends StatefulWidget {
  const _AvatarCameraButton({
    super.key,
    required this.uploading,
    required this.onTap,
  });

  final bool uploading;
  final VoidCallback onTap;

  @override
  State<_AvatarCameraButton> createState() => _AvatarCameraButtonState();
}

class _AvatarCameraButtonState extends State<_AvatarCameraButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Change avatar',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.uploading ? null : widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.88 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutBack,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [MocoColors.accentPrimary, _cameraPurple],
                ),
                border: Border.all(
                  color: MocoColors.backgroundPrimary,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: MocoColors.accentPrimary.withValues(alpha: 0.38),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: widget.uploading
                  ? const Padding(
                      padding: EdgeInsets.all(5),
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.camera_alt_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
            ),
          ),
        ),
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
            color: selected
                ? MocoColors.textOnAccent
                : MocoColors.textSecondary,
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
    Future.microtask(() {
      ref.read(profileControllerProvider.notifier).loadEarnings();
      // KYC review happens elsewhere (admin console), so the cached user can
      // be stale; re-read it so an approval shows up without a restart.
      ref.read(authActionsProvider).refreshUser();
    });
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
        // Not eligible: the server's own answer to "why can't I go online?"
        // in the spot the switch would occupy.
        if (listener != null && !listener.isEligible) ...[
          const SizedBox(height: MocoSpacing.md),
          ListenerEligibilityCard(
            listener: listener,
            onOpenApplication: () => context.push(Routes.listenerApplication),
          ),
        ],
        // Only an ELIGIBLE listener (approved KYC + minimum photos) gets the
        // switch; the backend refuses anyone else regardless.
        if (listener?.isEligible ?? false) ...[
          const SizedBox(height: MocoSpacing.md),
          _AvailabilityCard(
            key: const Key('profile_availability_card'),
            isOnline: listener?.isOnline ?? false,
            isBusy: state.isTogglingAvailability,
            error: state.availabilityError,
            canGoOnline: ref
                .watch(platformCapabilitiesProvider)
                .supportsCalling,
            onChanged: controller.setAvailability,
          ),
        ],
        if (listener != null) ...[
          const SizedBox(height: MocoSpacing.sm),
          _NavRow(
            key: const Key('profile_listener_application_row'),
            icon: Icons.photo_library_outlined,
            label: 'Photos & verification',
            onTap: () => context.push(Routes.listenerApplication),
          ),
        ],
        const SizedBox(height: MocoSpacing.sm),
        _NavRow(
          key: const Key('profile_friend_requests_row'),
          icon: Icons.person_add_alt_1_outlined,
          label: 'Friend requests',
          onTap: () => context.push(Routes.friendRequests),
        ),
        const SizedBox(height: MocoSpacing.xl),
        MocoSectionHeader(title: 'Earnings'),
        const SizedBox(height: MocoSpacing.md),
        if (state.isLoadingEarnings && state.earnings == null)
          const MocoSkeleton(height: 90)
        else if (state.earningsError != null && state.earnings == null)
          Text(
            ApiErrorMapper.from(state.earningsError!).message,
            style: TextStyle(color: MocoColors.danger, fontSize: 13),
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
      'approved' => (
        'Verified listener',
        MocoColors.success,
        Icons.verified_rounded,
      ),
      'pending' => (
        'Verification pending',
        MocoColors.warning,
        Icons.hourglass_top_rounded,
      ),
      'rejected' => (
        'Verification rejected',
        MocoColors.danger,
        Icons.error_outline_rounded,
      ),
      _ => (
        'Not yet verified',
        MocoColors.textMuted,
        Icons.info_outline_rounded,
      ),
    };

    return MocoGlassCard(
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
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
    this.canGoOnline = true,
  });

  final bool isOnline;
  final bool isBusy;
  final ApiException? error;
  final ValueChanged<bool> onChanged;

  /// False where calls cannot be answered (web): going online there would
  /// route paying callers to a device that can only show "answer elsewhere".
  /// Going offline is always allowed.
  final bool canGoOnline;

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
                  style: TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                key: const Key('profile_availability_switch'),
                value: isOnline,
                onChanged: isBusy || (!isOnline && !canGoOnline)
                    ? null
                    : onChanged,
                activeThumbColor: MocoColors.accentPrimary,
              ),
            ],
          ),
          if (!canGoOnline) ...[
            const SizedBox(height: MocoSpacing.sm),
            Text(
              PlatformCapabilities.goOnlineUnavailableMessage,
              key: const Key('profile_go_online_unavailable'),
              style: TextStyle(color: MocoColors.textMuted, fontSize: 12.5),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: MocoSpacing.sm),
            Text(
              ApiErrorMapper.from(error!).message,
              style: TextStyle(color: MocoColors.danger, fontSize: 12.5),
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
          Text(
            label,
            style: TextStyle(color: MocoColors.textMuted, fontSize: 12),
          ),
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
      padding: const EdgeInsets.symmetric(
        horizontal: MocoSpacing.lg,
        vertical: MocoSpacing.md,
      ),
      child: Row(
        children: [
          Icon(icon, color: MocoColors.accentSoft, size: 20),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) ...[
            Text(
              trailing!,
              style: TextStyle(color: MocoColors.textMuted, fontSize: 13),
            ),
            const SizedBox(width: MocoSpacing.sm),
          ],
          Icon(Icons.chevron_right_rounded, color: MocoColors.textMuted),
        ],
      ),
    );
  }
}
