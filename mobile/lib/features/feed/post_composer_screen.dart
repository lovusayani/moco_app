import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/moco_colors.dart';
import '../../core/theme/moco_spacing.dart';
import '../../core/widgets/moco_background.dart';
import '../../core/widgets/moco_surfaces.dart';
import '../../shared/models/feed.dart';
import 'feed_controller.dart';
import 'post_composer_controller.dart';

/// Picks media and returns its bytes. Injected so the composer can be tested
/// without the platform picker — there is no headless image picker.
typedef MediaPicker =
    Future<PickedMedia?> Function({required bool video});

class PickedMedia {
  const PickedMedia({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

final mediaPickerProvider = Provider<MediaPicker>((ref) {
  final picker = ImagePicker();
  return ({required bool video}) async {
    final file = video
        ? await picker.pickVideo(
            source: ImageSource.gallery,
            // Matches FEED_MEDIA.maxVideoSeconds on the backend, which
            // re-checks nothing about duration — this is the only place a
            // too-long clip is prevented, so it is a real limit, not a hint.
            maxDuration: const Duration(seconds: 60),
          )
        : await picker.pickImage(
            source: ImageSource.gallery,
            // Downscale before upload. A modern phone photo is far larger than
            // any feed needs, and shrinking here saves the user's data as well
            // as keeping the upload under the server's cap.
            maxWidth: 1440,
            maxHeight: 2560,
            imageQuality: 88,
          );
    if (file == null) return null;

    final mimeType =
        file.mimeType ?? PostMediaMimeTypes.forFileName(file.name);
    if (mimeType == null) return null;

    return PickedMedia(
      bytes: await file.readAsBytes(),
      fileName: file.name,
      mimeType: mimeType,
    );
  };
});

/// The post composer. Deliberately not an editor: choose media, optionally
/// caption it, publish. No filters, no cropping, no drafts — none of that is
/// in the approved design.
class PostComposerScreen extends ConsumerStatefulWidget {
  const PostComposerScreen({super.key});

  @override
  ConsumerState<PostComposerScreen> createState() => _PostComposerScreenState();
}

class _PostComposerScreenState extends ConsumerState<PostComposerScreen> {
  final TextEditingController _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool video}) async {
    final picked = await ref.read(mediaPickerProvider)(video: video);
    if (picked == null || !mounted) return;
    ref
        .read(postComposerControllerProvider.notifier)
        .pickedMedia(
          bytes: picked.bytes,
          fileName: picked.fileName,
          mimeType: picked.mimeType,
        );
  }

  Future<void> _publish() async {
    final post = await ref.read(postComposerControllerProvider.notifier).publish();
    if (post == null || !mounted) return;

    // The post exists on the server before it exists in the feed. Prepending
    // here is a display shortcut over a refetch, not an optimistic guess.
    ref.read(feedControllerProvider.notifier).prepend(post);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(postComposerControllerProvider);
    final controller = ref.read(postComposerControllerProvider.notifier);

    return Scaffold(
      backgroundColor: MocoColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('New post'),
        leading: IconButton(
          key: const Key('composer_close'),
          icon: const Icon(Icons.close_rounded),
          onPressed: state.isBusy ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: MocoBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MocoSpacing.screenPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MediaSlot(
                  state: state,
                  onPickImage: state.isBusy ? null : () => _pick(video: false),
                  onPickVideo: state.isBusy ? null : () => _pick(video: true),
                  onClear: state.isBusy ? null : controller.clearMedia,
                ),
                const SizedBox(height: MocoSpacing.xl),
                TextField(
                  key: const Key('composer_caption'),
                  controller: _caption,
                  enabled: !state.isBusy,
                  onChanged: controller.captionChanged,
                  maxLines: 4,
                  minLines: 2,
                  maxLength: 500,
                  style: const TextStyle(color: MocoColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'Add a caption (optional)',
                    counterStyle: TextStyle(color: MocoColors.textMuted),
                  ),
                ),
                if (state.stage == PublishStage.uploading ||
                    state.stage == PublishStage.saving) ...[
                  const SizedBox(height: MocoSpacing.md),
                  _Progress(state: state),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: MocoSpacing.md),
                  _ErrorBanner(
                    message: ApiErrorMapper.from(state.error!).message,
                  ),
                ],
                const SizedBox(height: MocoSpacing.xl),
                MocoPrimaryButton(
                  key: const Key('composer_publish'),
                  label: state.error != null ? 'Try again' : 'Publish',
                  loading: state.isBusy,
                  onPressed: state.canPublish ? _publish : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaSlot extends StatelessWidget {
  const _MediaSlot({
    required this.state,
    this.onPickImage,
    this.onPickVideo,
    this.onClear,
  });

  final ComposerState state;
  final VoidCallback? onPickImage;
  final VoidCallback? onPickVideo;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    if (!state.hasMedia) {
      return Column(
        children: [
          _PickTile(
            key: const Key('composer_pick_image'),
            icon: Icons.image_outlined,
            label: 'Choose a photo',
            onTap: onPickImage,
          ),
          const SizedBox(height: MocoSpacing.md),
          _PickTile(
            key: const Key('composer_pick_video'),
            icon: Icons.videocam_outlined,
            label: 'Choose a video',
            subtitle: 'Up to 60 seconds',
            onTap: onPickVideo,
          ),
        ],
      );
    }

    return MocoGlassCard(
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: MocoColors.surfaceGlass,
              borderRadius: BorderRadius.circular(MocoRadius.sm),
            ),
            child: Icon(
              state.isVideo ? Icons.videocam_rounded : Icons.image_rounded,
              color: MocoColors.accentSoft,
            ),
          ),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.fileName ?? 'Selected media',
                  key: const Key('composer_selected_name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _sizeLabel(state.bytes!.length),
                  style: const TextStyle(
                    color: MocoColors.textMuted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (onClear != null)
            IconButton(
              key: const Key('composer_clear_media'),
              onPressed: onClear,
              icon: const Icon(
                Icons.close_rounded,
                color: MocoColors.textMuted,
              ),
              tooltip: 'Remove',
            ),
        ],
      ),
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MocoGlassCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: MocoColors.accentSoft, size: 26),
          const SizedBox(width: MocoSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: MocoColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: MocoColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: MocoColors.textMuted,
          ),
        ],
      ),
    );
  }
}

/// Real progress for the upload, and an indeterminate bar for the short
/// metadata save. Showing determinate progress for a step that has none would
/// be a fake progress bar.
class _Progress extends StatelessWidget {
  const _Progress({required this.state});

  final ComposerState state;

  @override
  Widget build(BuildContext context) {
    final uploading = state.stage == PublishStage.uploading;
    return Column(
      key: const Key('composer_progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          uploading
              ? 'Uploading… ${(state.uploadProgress * 100).round()}%'
              : 'Publishing…',
          style: const TextStyle(
            color: MocoColors.textSecondary,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: MocoSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(MocoRadius.pill),
          child: LinearProgressIndicator(
            value: uploading ? state.uploadProgress : null,
            minHeight: 6,
            backgroundColor: MocoColors.surfaceGlass,
            valueColor: const AlwaysStoppedAnimation(
              MocoColors.accentPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('composer_error'),
      padding: const EdgeInsets.all(MocoSpacing.md),
      decoration: BoxDecoration(
        color: MocoColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MocoRadius.sm),
        border: Border.all(color: MocoColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: MocoColors.danger,
            size: 20,
          ),
          const SizedBox(width: MocoSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: MocoColors.textPrimary,
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
