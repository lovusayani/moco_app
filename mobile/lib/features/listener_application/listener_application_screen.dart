import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/platform/platform_capabilities.dart';
import '../../core/providers.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_states.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/listener_photos.dart';
import '../../shared/models/user.dart';
import 'listener_application_controller.dart';

/// Picks one image. Injectable so widget tests never open a real picker.
typedef ListenerPhotoPicker = Future<({String name, Uint8List bytes})?> Function();

final listenerPhotoPickerProvider = Provider<ListenerPhotoPicker>((ref) {
  return () async {
    // Resized/re-encoded on device so typical phone photos land well under
    // the 8 MB server cap; the size is still checked before upload.
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  };
});

/// The listener application: profile photos, identity verification, and
/// exactly what still stands between this listener and going online.
///
/// Every rule here is enforced by the backend; this screen only prevents
/// obviously invalid submissions and explains the server's current answer.
class ListenerApplicationScreen extends ConsumerStatefulWidget {
  const ListenerApplicationScreen({super.key});

  @override
  ConsumerState<ListenerApplicationScreen> createState() => _ListenerApplicationScreenState();
}

class _ListenerApplicationScreenState extends ConsumerState<ListenerApplicationScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(listenerApplicationControllerProvider.notifier).load();
      // Re-read the user so status and blockers are current on arrival.
      ref.read(authActionsProvider).refreshUser();
    });
  }

  @override
  Widget build(BuildContext context) {
    final listener = ref.watch(authControllerProvider).user?.listener;
    final state = ref.watch(listenerApplicationControllerProvider);
    final controller = ref.read(listenerApplicationControllerProvider.notifier);

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Listener application')),
      body: MocoBackground(
        child: SafeArea(
          child: listener == null
              ? const MocoEmptyState(
                  title: 'Not a listener yet',
                  message: 'Apply to become a listener from your profile first.',
                  icon: Icons.mic_none_rounded,
                )
              : RefreshIndicator(
                  color: MocoColors.accentPrimary,
                  onRefresh: () async {
                    await controller.load();
                    await ref.read(authActionsProvider).refreshUser();
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(MocoSpacing.screenPadding),
                    children: [
                      ListenerEligibilityCard(listener: listener),
                      const SizedBox(height: MocoSpacing.xl),
                      MocoSectionHeader(
                        title: 'Profile photos',
                        subtitle:
                            'At least ${listener.minPhotos} photos of you — up to ${listener.maxPhotos}. JPEG, PNG or WebP.',
                      ),
                      const SizedBox(height: MocoSpacing.md),
                      _PhotosSection(listener: listener, state: state),
                      const SizedBox(height: MocoSpacing.xl),
                      MocoSectionHeader(title: 'Identity verification'),
                      const SizedBox(height: MocoSpacing.md),
                      _KycSection(listener: listener, state: state),
                      const SizedBox(height: MocoSpacing.xxl),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// "Can I go online, and if not, why not?" — straight from the server's
/// blockers. Shown on this screen and on Profile.
class ListenerEligibilityCard extends ConsumerWidget {
  const ListenerEligibilityCard({super.key, required this.listener, this.onOpenApplication});

  final ListenerState listener;
  final VoidCallback? onOpenApplication;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reasons = listenerEligibilityReasons(listener);
    final eligible = listener.isEligible && reasons.isEmpty;
    final canCallHere = ref.watch(platformCapabilitiesProvider).supportsCalling;

    return MocoGlassCard(
      key: const Key('listener_eligibility_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                eligible ? Icons.verified_rounded : Icons.lock_clock_rounded,
                color: eligible ? MocoColors.success : MocoColors.warning,
                size: 22,
              ),
              const SizedBox(width: MocoSpacing.md),
              Expanded(
                child: Text(
                  eligible ? 'You can go online and take calls' : 'Not ready to go online yet',
                  style: TextStyle(color: MocoColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (!eligible) ...[
            const SizedBox(height: MocoSpacing.sm),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.radio_button_unchecked_rounded, size: 16, color: MocoColors.textMuted),
                    const SizedBox(width: MocoSpacing.sm),
                    Expanded(
                      child: Text(
                        reason,
                        key: Key('eligibility_reason_${reasons.indexOf(reason)}'),
                        style: TextStyle(color: MocoColors.textSecondary, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (eligible && !canCallHere) ...[
            const SizedBox(height: MocoSpacing.sm),
            Text(
              PlatformCapabilities.goOnlineUnavailableMessage,
              style: TextStyle(color: MocoColors.textMuted, fontSize: 12.5),
            ),
          ],
          if (onOpenApplication != null && !eligible) ...[
            const SizedBox(height: MocoSpacing.md),
            MocoSecondaryButton(
              key: const Key('open_listener_application'),
              label: 'Complete your application',
              icon: Icons.arrow_forward_rounded,
              onPressed: onOpenApplication,
            ),
          ],
        ],
      ),
    );
  }
}

class _PhotosSection extends ConsumerWidget {
  const _PhotosSection({required this.listener, required this.state});

  final ListenerState listener;
  final ListenerApplicationState state;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final picked = await ref.read(listenerPhotoPickerProvider)();
    if (picked == null) return;
    await ref
        .read(listenerApplicationControllerProvider.notifier)
        .addPhoto(fileName: picked.name, bytes: picked.bytes);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, ListenerPhoto photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: MocoColors.backgroundElevated,
        title: const Text('Remove this photo?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm_remove_photo'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Remove', style: TextStyle(color: MocoColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(listenerApplicationControllerProvider.notifier).removePhoto(photo.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isLoading && state.photos == null) return const MocoSkeleton(height: 120);
    if (state.loadError != null && state.photos == null) {
      return Text(state.loadError!.message, style: TextStyle(color: MocoColors.danger, fontSize: 13));
    }
    final photos = state.photos ?? const ListenerPhotos();
    final canAdd = !photos.atMaximum;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${photos.count} of ${photos.minCount} required'
          '${photos.meetsMinimum ? ' ✓' : ''}',
          key: const Key('listener_photo_count'),
          style: TextStyle(
            color: photos.meetsMinimum ? MocoColors.success : MocoColors.warning,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: MocoSpacing.sm),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: MocoSpacing.sm,
          crossAxisSpacing: MocoSpacing.sm,
          children: [
            for (final photo in photos.photos)
              _PhotoTile(
                key: Key('listener_photo_${photo.id}'),
                photo: photo,
                deleting: state.deletingPhotoId == photo.id,
                onRemove: state.isUploading || state.deletingPhotoId != null
                    ? null
                    : () => _remove(context, ref, photo),
              ),
            if (canAdd)
              _AddPhotoTile(
                progress: state.uploadProgress,
                onTap: state.isUploading ? null : () => _add(context, ref),
              ),
          ],
        ),
        if (state.photoError != null) ...[
          const SizedBox(height: MocoSpacing.sm),
          Text(
            state.photoError!,
            key: const Key('listener_photo_error'),
            style: TextStyle(color: MocoColors.danger, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({super.key, required this.photo, required this.deleting, this.onRemove});

  final ListenerPhoto photo;
  final bool deleting;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(MocoRadius.md),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: MocoColors.surfaceGlass),
          if (photo.url != null)
            Image.network(
              photo.url!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, color: MocoColors.textMuted),
            ),
          if (deleting)
            Container(
              color: Colors.black45,
              alignment: Alignment.center,
              child: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                key: Key('remove_photo_${photo.id}'),
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({this.progress, this.onTap});

  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MocoColors.surfaceGlass,
      borderRadius: BorderRadius.circular(MocoRadius.md),
      child: InkWell(
        key: const Key('add_listener_photo'),
        borderRadius: BorderRadius.circular(MocoRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MocoRadius.md),
            border: Border.all(color: MocoColors.borderStrong),
          ),
          alignment: Alignment.center,
          child: progress == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: MocoColors.accentSoft),
                    const SizedBox(height: 6),
                    Text('Add photo', style: TextStyle(color: MocoColors.textSecondary, fontSize: 12.5)),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.all(MocoSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        key: const Key('listener_photo_progress'),
                        value: progress == 0 ? null : progress,
                        color: MocoColors.accentPrimary,
                        backgroundColor: MocoColors.surfaceGlassStrong,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Uploading ${((progress ?? 0) * 100).round()}%',
                        style: TextStyle(color: MocoColors.textMuted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _KycSection extends ConsumerStatefulWidget {
  const _KycSection({required this.listener, required this.state});

  final ListenerState listener;
  final ListenerApplicationState state;

  @override
  ConsumerState<_KycSection> createState() => _KycSectionState();
}

class _KycSectionState extends ConsumerState<_KycSection> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _doc = TextEditingController();
  final _upi = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _doc.dispose();
    _upi.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final ok = await ref.read(listenerApplicationControllerProvider.notifier).submitKyc(
      fullName: _name.text.trim(),
      docUrl: _doc.text.trim(),
      upiId: _upi.text.trim(),
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submitted for review. We will notify you when it is checked.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.listener;
    final photosMissing = (l.minPhotos - (widget.state.photos?.count ?? l.photoCount)).clamp(0, l.minPhotos);
    final serverError = widget.state.kycError;

    final statusCard = switch (l.kycStatus) {
      'approved' => _StatusLine(
          icon: Icons.verified_rounded,
          color: MocoColors.success,
          title: 'Verified',
          detail: 'Your identity has been verified.',
        ),
      'pending' => _StatusLine(
          icon: Icons.hourglass_top_rounded,
          color: MocoColors.warning,
          title: 'Under review',
          detail: l.kycSubmittedAt == null
              ? 'A person is reviewing your application.'
              : 'Submitted ${_date(l.kycSubmittedAt!)}. A person is reviewing your application.',
        ),
      'rejected' => _StatusLine(
          icon: Icons.error_outline_rounded,
          color: MocoColors.danger,
          title: 'Not approved',
          detail: (l.kycRejectionReason?.trim().isNotEmpty ?? false)
              ? 'Reason: ${l.kycRejectionReason}'
              : 'Your application was not approved. Update your details and resubmit.',
        ),
      _ => _StatusLine(
          icon: Icons.badge_outlined,
          color: MocoColors.textMuted,
          title: 'Not submitted',
          detail: 'Submit your details for a one-time manual review.',
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyedSubtree(key: Key('kyc_status_${l.kycStatus}'), child: statusCard),
        if (l.canSubmitKyc) ...[
          const SizedBox(height: MocoSpacing.md),
          MocoGlassCard(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    key: const Key('kyc_full_name'),
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Full legal name'),
                    validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name as on your ID' : null,
                  ),
                  const SizedBox(height: MocoSpacing.md),
                  TextFormField(
                    key: const Key('kyc_doc_url'),
                    controller: _doc,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'ID document link',
                      helperText: 'A private link to a photo of your government ID, viewable by Moco reviewers.',
                      helperMaxLines: 2,
                    ),
                    validator: (v) {
                      final uri = Uri.tryParse((v ?? '').trim());
                      final valid = uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;
                      return valid ? null : 'Enter a valid https:// link';
                    },
                  ),
                  const SizedBox(height: MocoSpacing.md),
                  TextFormField(
                    key: const Key('kyc_upi'),
                    controller: _upi,
                    decoration: const InputDecoration(labelText: 'UPI ID (for payouts)', hintText: 'name@bank'),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      return t.length >= 3 && t.contains('@') ? null : 'Enter a UPI ID like name@bank';
                    },
                  ),
                  if (serverError != null) ...[
                    const SizedBox(height: MocoSpacing.md),
                    Text(
                      serverError.message,
                      key: const Key('kyc_error'),
                      style: TextStyle(color: MocoColors.danger, fontSize: 12.5),
                    ),
                  ],
                  if (photosMissing > 0) ...[
                    const SizedBox(height: MocoSpacing.md),
                    Text(
                      'Add $photosMissing more photo${photosMissing == 1 ? '' : 's'} before submitting.',
                      key: const Key('kyc_needs_photos'),
                      style: TextStyle(color: MocoColors.warning, fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ],
                  const SizedBox(height: MocoSpacing.lg),
                  MocoPrimaryButton(
                    key: const Key('kyc_submit'),
                    label: l.wasRejected ? 'Resubmit for review' : 'Submit for review',
                    loading: widget.state.isSubmittingKyc,
                    // Obvious-invalid prevention only — the backend refuses
                    // (photos_required) regardless of what this button allows.
                    onPressed: photosMissing > 0 ? null : _submit,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _date(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final local = d.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.color, required this.title, required this.detail});

  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: color, fontSize: 14.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail, style: TextStyle(color: MocoColors.textSecondary, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
