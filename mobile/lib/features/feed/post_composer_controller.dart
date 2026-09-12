import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/feed_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/feed.dart';

/// Where a publish attempt is in the three-step flow. The UI needs to tell
/// "uploading 40%" from "saving the post" apart, because only the first has
/// meaningful progress and only the second is quick.
enum PublishStage { idle, uploading, saving, done }

class ComposerState {
  const ComposerState({
    this.bytes,
    this.fileName,
    this.mimeType,
    this.mediaType,
    this.caption = '',
    this.stage = PublishStage.idle,
    this.uploadProgress = 0,
    this.error,
    this.published,
  });

  /// The picked file, held in memory only until it is uploaded.
  final Uint8List? bytes;
  final String? fileName;
  final String? mimeType;
  final PostMediaType? mediaType;
  final String caption;

  final PublishStage stage;

  /// 0..1 for the direct-to-storage upload. Not synthetic — it comes from
  /// Dio's send progress, so a stalled upload visibly stalls.
  final double uploadProgress;

  final ApiException? error;

  /// Set only after the backend has accepted the post. Nothing is added to the
  /// feed before this exists.
  final Post? published;

  bool get hasMedia => bytes != null && bytes!.isNotEmpty;
  bool get isBusy =>
      stage == PublishStage.uploading || stage == PublishStage.saving;
  bool get canPublish => hasMedia && !isBusy;
  bool get isVideo => mediaType == PostMediaType.video;

  ComposerState copyWith({
    Uint8List? bytes,
    String? fileName,
    String? mimeType,
    PostMediaType? mediaType,
    String? caption,
    PublishStage? stage,
    double? uploadProgress,
    ApiException? error,
    Post? published,
    bool clearError = false,
  }) {
    return ComposerState(
      bytes: bytes ?? this.bytes,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      mediaType: mediaType ?? this.mediaType,
      caption: caption ?? this.caption,
      stage: stage ?? this.stage,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      error: clearError ? null : (error ?? this.error),
      published: published ?? this.published,
    );
  }
}

/// Publishes one post: authorize → upload direct to storage → save metadata.
///
/// The media never passes through the Moco API, which is why the upload is a
/// bare Dio client here rather than the app's [ApiClient]: the signed URL
/// points at Supabase Storage and carries its own one-time token, and sending
/// this app's session token to a third-party host would leak it.
///
/// A post exists only when all three steps succeed. A failure at any step
/// leaves the picked media in place so Retry is one tap and does not make the
/// user choose the file again.
class PostComposerController extends StateNotifier<ComposerState> {
  PostComposerController(this._api, {Dio? uploadClient})
    : _uploadClient = uploadClient ?? Dio(),
      super(const ComposerState());

  final FeedApi _api;
  final Dio _uploadClient;

  /// Cancels an in-flight upload when the composer is closed, so a discarded
  /// post does not keep pushing bytes in the background.
  CancelToken? _uploadCancel;

  void pickedMedia({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) {
    state = ComposerState(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      mediaType: PostMediaMimeTypes.video.contains(mimeType)
          ? PostMediaType.video
          : PostMediaType.image,
      caption: state.caption,
    );
  }

  void captionChanged(String value) {
    state = state.copyWith(caption: value);
  }

  void clearMedia() {
    _uploadCancel?.cancel('composer cleared');
    _uploadCancel = null;
    state = ComposerState(caption: state.caption);
  }

  /// Runs the full publish. Returns the created post, or null on any failure —
  /// the failure is also on [ComposerState.error] for the UI to render.
  Future<Post?> publish() async {
    final bytes = state.bytes;
    final mimeType = state.mimeType;
    if (bytes == null || mimeType == null || state.isBusy) return null;

    state = state.copyWith(
      stage: PublishStage.uploading,
      uploadProgress: 0,
      clearError: true,
    );

    try {
      final auth = await _api.requestUploadUrl(mimeType);

      // Check the real size against the cap the server just published, before
      // spending the upload. The server enforces it again after the fact —
      // this only saves the user a wasted transfer, it is not the guarantee.
      if (bytes.length > auth.maxBytes) {
        final mb = (auth.maxBytes / (1024 * 1024)).round();
        throw ApiException(
          kind: ApiErrorKind.validation,
          message: state.isVideo
              ? 'That video is too large. Videos must be under ${mb}MB.'
              : 'That photo is too large. Photos must be under ${mb}MB.',
        );
      }

      _uploadCancel = CancelToken();
      await _uploadClient.put<dynamic>(
        auth.uploadUrl,
        data: Stream.fromIterable([bytes]),
        cancelToken: _uploadCancel,
        onSendProgress: (sent, total) {
          if (total <= 0 || !mounted) return;
          state = state.copyWith(uploadProgress: (sent / total).clamp(0, 1));
        },
        options: Options(
          headers: {
            // Supabase Storage's signed-upload protocol: a one-time,
            // storage-scoped token, NOT this app's session token.
            'Authorization': 'Bearer ${auth.token}',
            'Content-Type': mimeType,
            'Content-Length': bytes.length,
            'x-upsert': 'false',
          },
          contentType: mimeType,
        ),
      );
      _uploadCancel = null;

      if (!mounted) return null;
      state = state.copyWith(stage: PublishStage.saving, uploadProgress: 1);

      // Only now does the post exist. The media type is not sent — the server
      // derives it from the path it minted.
      final post = await _api.createPost(
        mediaPath: auth.path,
        caption: state.caption,
      );

      if (!mounted) return post;
      state = state.copyWith(stage: PublishStage.done, published: post);
      return post;
    } on ApiException catch (e) {
      if (mounted) state = state.copyWith(stage: PublishStage.idle, error: e);
      return null;
    } catch (e) {
      if (!mounted) return null;
      final cancelled = e is DioException && CancelToken.isCancel(e);
      if (cancelled) {
        state = state.copyWith(stage: PublishStage.idle);
        return null;
      }
      state = state.copyWith(
        stage: PublishStage.idle,
        error: const ApiException(
          kind: ApiErrorKind.unknown,
          message: 'The upload did not finish. Please try again.',
        ),
      );
      return null;
    }
  }

  @override
  void dispose() {
    _uploadCancel?.cancel('composer disposed');
    super.dispose();
  }
}

/// The raw HTTP client used to PUT media to Supabase Storage.
///
/// Deliberately NOT the app's [ApiClient]: the signed URL points at a
/// third-party host and carries its own one-time token, so sending this app's
/// session token along with it would leak the credential. Kept as a provider
/// so a test can supply its own client.
final storageUploadClientProvider = Provider<Dio>((ref) => Dio());

final postComposerControllerProvider = StateNotifierProvider.autoDispose<
  PostComposerController,
  ComposerState
>(
  (ref) => PostComposerController(
    ref.watch(feedApiProvider),
    uploadClient: ref.watch(storageUploadClientProvider),
  ),
);
