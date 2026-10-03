import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/listeners_api.dart';
import '../../core/errors/api_exception.dart';
import '../../core/providers.dart';
import '../../shared/models/listener_photos.dart';

/// PUTs raw bytes to a Supabase signed upload URL. Injectable so the
/// controller is testable without a network; the real one is [dioPhotoUploader].
typedef PhotoUploader = Future<void> Function({
  required String uploadUrl,
  required String token,
  required String mimeType,
  required Uint8List bytes,
  required void Function(double progress) onProgress,
});

/// Supabase Storage's signed-upload protocol: PUT the bytes to the signed URL,
/// bearer-authorized with the one-time storage token it issued (not the app's
/// session token). Same shape chat photos and feed posts use.
Future<void> dioPhotoUploader({
  required String uploadUrl,
  required String token,
  required String mimeType,
  required Uint8List bytes,
  required void Function(double progress) onProgress,
}) async {
  await Dio().put<dynamic>(
    uploadUrl,
    data: Stream.fromIterable([bytes]),
    onSendProgress: (sent, total) {
      if (total > 0) onProgress(sent / total);
    },
    options: Options(
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': mimeType,
        'Content-Length': bytes.length,
        'x-upsert': 'false',
      },
      contentType: mimeType,
    ),
  );
}

final photoUploaderProvider = Provider<PhotoUploader>((ref) => dioPhotoUploader);

/// The MIME type for a picked file, from its extension — or null when it is
/// not one of the image types the backend accepts. Checked BEFORE asking the
/// backend for an upload URL; the backend validates again regardless.
String? listenerPhotoMimeType(String fileName) {
  final name = fileName.toLowerCase();
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  return null;
}

@immutable
class ListenerApplicationState {
  const ListenerApplicationState({
    this.photos,
    this.isLoading = false,
    this.loadError,
    this.uploadProgress,
    this.deletingPhotoId,
    this.photoError,
    this.isSubmittingKyc = false,
    this.kycError,
  });

  final ListenerPhotos? photos;
  final bool isLoading;
  final ApiException? loadError;

  /// 0..1 while a photo upload is in flight, otherwise null.
  final double? uploadProgress;
  final int? deletingPhotoId;
  final String? photoError;

  final bool isSubmittingKyc;
  final ApiException? kycError;

  bool get isUploading => uploadProgress != null;

  ListenerApplicationState copyWith({
    ListenerPhotos? photos,
    bool? isLoading,
    ApiException? loadError,
    double? uploadProgress,
    int? deletingPhotoId,
    String? photoError,
    bool? isSubmittingKyc,
    ApiException? kycError,
    bool clearLoadError = false,
    bool clearUpload = false,
    bool clearDeleting = false,
    bool clearPhotoError = false,
    bool clearKycError = false,
  }) {
    return ListenerApplicationState(
      photos: photos ?? this.photos,
      isLoading: isLoading ?? this.isLoading,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      uploadProgress: clearUpload ? null : (uploadProgress ?? this.uploadProgress),
      deletingPhotoId: clearDeleting ? null : (deletingPhotoId ?? this.deletingPhotoId),
      photoError: clearPhotoError ? null : (photoError ?? this.photoError),
      isSubmittingKyc: isSubmittingKyc ?? this.isSubmittingKyc,
      kycError: clearKycError ? null : (kycError ?? this.kycError),
    );
  }
}

/// The listener application: profile photos + identity verification.
///
/// Nothing here decides eligibility. Every action is a backend call; after
/// each one that can change eligibility the signed-in user is re-read, so
/// the blockers the app shows are always the server's current answer.
class ListenerApplicationController extends StateNotifier<ListenerApplicationState> {
  ListenerApplicationController(this._api, this._upload, this._refreshUser)
    : super(const ListenerApplicationState());

  final ListenersApi _api;
  final PhotoUploader _upload;
  final Future<void> Function() _refreshUser;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearLoadError: true);
    try {
      final photos = await _api.myPhotos();
      state = state.copyWith(photos: photos, isLoading: false);
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, loadError: e);
    }
  }

  /// Validates, uploads and registers one picked image. Returns true on
  /// success; on failure [ListenerApplicationState.photoError] says why.
  Future<bool> addPhoto({required String fileName, required Uint8List bytes}) async {
    if (state.isUploading) return false;
    final photos = state.photos;
    if (photos != null && photos.atMaximum) {
      state = state.copyWith(photoError: 'You can have at most ${photos.maxCount} photos.');
      return false;
    }
    final mimeType = listenerPhotoMimeType(fileName);
    if (mimeType == null) {
      state = state.copyWith(photoError: 'Only JPEG, PNG or WebP photos can be used.');
      return false;
    }

    state = state.copyWith(uploadProgress: 0, clearPhotoError: true);
    try {
      final auth = await _api.requestPhotoUploadUrl(mimeType);
      if (bytes.length > auth.maxBytes) {
        final mb = (auth.maxBytes / (1024 * 1024)).round();
        state = state.copyWith(clearUpload: true, photoError: 'That photo is too large (max $mb MB).');
        return false;
      }
      await _upload(
        uploadUrl: auth.uploadUrl,
        token: auth.token,
        mimeType: mimeType,
        bytes: bytes,
        onProgress: (p) {
          if (mounted) state = state.copyWith(uploadProgress: p.clamp(0, 1).toDouble());
        },
      );
      final updated = await _api.registerPhoto(auth.path);
      state = state.copyWith(photos: updated, clearUpload: true);
      await _refreshUser();
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(clearUpload: true, photoError: e.message);
      return false;
    } on DioException catch (e) {
      state = state.copyWith(clearUpload: true, photoError: ApiErrorMapper.fromDioException(e).message);
      return false;
    }
  }

  Future<bool> removePhoto(int photoId) async {
    if (state.deletingPhotoId != null) return false;
    state = state.copyWith(deletingPhotoId: photoId, clearPhotoError: true);
    try {
      final updated = await _api.deletePhoto(photoId);
      state = state.copyWith(photos: updated, clearDeleting: true);
      await _refreshUser();
      return true;
    } on ApiException catch (e) {
      // e.g. photos_minimum: a verified listener must keep the minimum.
      state = state.copyWith(clearDeleting: true, photoError: e.message);
      return false;
    }
  }

  Future<bool> submitKyc({
    required String fullName,
    required String docUrl,
    required String upiId,
  }) async {
    if (state.isSubmittingKyc) return false;
    state = state.copyWith(isSubmittingKyc: true, clearKycError: true);
    try {
      await _api.submitKyc(fullName: fullName, docUrl: docUrl, upiId: upiId);
      state = state.copyWith(isSubmittingKyc: false);
      await _refreshUser();
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isSubmittingKyc: false, kycError: e);
      return false;
    }
  }

  void clearPhotoError() => state = state.copyWith(clearPhotoError: true);
}

final listenerApplicationControllerProvider = StateNotifierProvider.autoDispose<
  ListenerApplicationController,
  ListenerApplicationState
>((ref) {
  return ListenerApplicationController(
    ref.watch(listenersApiProvider),
    ref.watch(photoUploaderProvider),
    () => ref.read(authActionsProvider).refreshUser(),
  );
});
