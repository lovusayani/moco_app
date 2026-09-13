import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';
import 'account_deletion_controller.dart';

/// Account settings. Deliberately small: sign out and account deletion are
/// the only two actions here — no invented preferences system.
class AccountSettingsScreen extends ConsumerWidget {
  const AccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = ref.watch(authControllerProvider).user?.phone;

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Account settings')),
      body: MocoBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(MocoSpacing.screenPadding),
            children: [
              if (phone != null)
                MocoGlassCard(
                  child: Row(
                    children: [
                      const Icon(Icons.phone_outlined, color: MocoColors.textMuted, size: 20),
                      const SizedBox(width: MocoSpacing.md),
                      Text(phone, style: const TextStyle(color: MocoColors.textSecondary, fontSize: 14)),
                    ],
                  ),
                ),
              const SizedBox(height: MocoSpacing.xl),
              MocoSecondaryButton(
                key: const Key('account_settings_logout'),
                label: 'Sign out',
                icon: Icons.logout_rounded,
                onPressed: () => _confirmSignOut(context, ref),
              ),
              const SizedBox(height: MocoSpacing.xxl),
              const Divider(color: MocoColors.borderSubtle),
              const SizedBox(height: MocoSpacing.lg),
              Text(
                'Danger zone',
                style: const TextStyle(
                  color: MocoColors.danger,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: MocoSpacing.md),
              MocoSecondaryButton(
                key: const Key('account_settings_delete'),
                label: 'Delete account',
                icon: Icons.delete_forever_outlined,
                onPressed: () => _confirmDeletion(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MocoColors.backgroundElevated,
        title: const Text('Sign out?'),
        content: const Text('You can sign back in any time with your phone number.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm_sign_out'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authActionsProvider).signOut();
    }
  }

  Future<void> _confirmDeletion(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MocoColors.backgroundElevated,
        title: const Text('Delete your account?'),
        content: const Text(
          'This removes your name, photo and profile from Moco. Your call and '
          'payment history is kept for financial records but is no longer '
          'linked to an active account. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm_delete_account'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete', style: TextStyle(color: MocoColors.danger)),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final success = await ref.read(accountDeletionControllerProvider.notifier).confirmDeletion();

    if (!context.mounted) return;
    if (!success) {
      final error = ref.read(accountDeletionControllerProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error != null ? ApiErrorMapper.from(error).message : 'Could not delete your account.',
          ),
        ),
      );
    }
    // On success, signOut() already cleared the session; the router's
    // auth-state redirect takes it from here — no manual navigation needed.
  }
}
