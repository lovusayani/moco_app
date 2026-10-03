import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/listener_application/listener_application_controller.dart';
import 'package:moco/shared/models/listener_photos.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

ListenerPhotos _photos(int n) => ListenerPhotos(
  photos: List.generate(n, (i) => ListenerPhoto(id: i + 1, url: 'https://signed/$i')),
);

const _auth = ListenerPhotoUploadAuthorization(
  path: '7/1_abc.jpg',
  uploadUrl: 'https://storage/upload',
  token: 'upload-token',
  maxBytes: 1000,
);

void main() {
  late _MockListenersApi api;
  late int refreshes;
  late List<Map<String, Object>> uploads;

  Future<void> fakeUpload({
    required String uploadUrl,
    required String token,
    required String mimeType,
    required Uint8List bytes,
    required void Function(double progress) onProgress,
  }) async {
    onProgress(0.5);
    onProgress(1);
    uploads.add({'url': uploadUrl, 'token': token, 'mime': mimeType, 'len': bytes.length});
  }

  ListenerApplicationController build() =>
      ListenerApplicationController(api, fakeUpload, () async => refreshes++);

  setUp(() {
    api = _MockListenersApi();
    refreshes = 0;
    uploads = [];
  });

  test('picks MIME type from the file name, image types only', () {
    expect(listenerPhotoMimeType('a.JPG'), 'image/jpeg');
    expect(listenerPhotoMimeType('a.jpeg'), 'image/jpeg');
    expect(listenerPhotoMimeType('a.png'), 'image/png');
    expect(listenerPhotoMimeType('a.webp'), 'image/webp');
    expect(listenerPhotoMimeType('a.gif'), isNull);
    expect(listenerPhotoMimeType('clip.mp4'), isNull);
  });

  test('a non-image is refused before any backend call', () async {
    final c = build();
    final ok = await c.addPhoto(fileName: 'clip.mp4', bytes: Uint8List(10));
    expect(ok, isFalse);
    expect(c.state.photoError, contains('JPEG, PNG or WebP'));
    verifyNever(() => api.requestPhotoUploadUrl(any()));
  });

  test('a photo is authorized, uploaded with the storage token, then registered', () async {
    when(() => api.requestPhotoUploadUrl('image/jpeg')).thenAnswer((_) async => _auth);
    when(() => api.registerPhoto('7/1_abc.jpg')).thenAnswer((_) async => _photos(1));
    final c = build();

    final ok = await c.addPhoto(fileName: 'me.jpg', bytes: Uint8List(500));

    expect(ok, isTrue);
    expect(uploads.single, {'url': 'https://storage/upload', 'token': 'upload-token', 'mime': 'image/jpeg', 'len': 500});
    expect(c.state.photos!.count, 1);
    expect(c.state.isUploading, isFalse);
    expect(refreshes, 1, reason: 'eligibility must be re-read from the server');
  });

  test('a photo over the server cap is refused before uploading', () async {
    when(() => api.requestPhotoUploadUrl('image/png')).thenAnswer((_) async => _auth);
    final c = build();

    final ok = await c.addPhoto(fileName: 'big.png', bytes: Uint8List(1001));

    expect(ok, isFalse);
    expect(uploads, isEmpty);
    expect(c.state.photoError, contains('too large'));
    verifyNever(() => api.registerPhoto(any()));
  });

  test('a backend refusal on registration is shown, not swallowed', () async {
    when(() => api.requestPhotoUploadUrl('image/jpeg')).thenAnswer((_) async => _auth);
    when(() => api.registerPhoto(any())).thenThrow(
      const ApiException(kind: ApiErrorKind.validation, code: 'photo_limit', message: 'You can have at most 6 photos'),
    );
    final c = build();

    final ok = await c.addPhoto(fileName: 'me.jpg', bytes: Uint8List(10));

    expect(ok, isFalse);
    expect(c.state.photoError, 'You can have at most 6 photos');
    expect(c.state.isUploading, isFalse);
  });

  test('removing below the verified minimum surfaces the server reason', () async {
    when(() => api.deletePhoto(2)).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        code: 'photos_minimum',
        message: 'Verified listeners need at least 3 photos. Add another before removing this one.',
      ),
    );
    final c = build();

    final ok = await c.removePhoto(2);

    expect(ok, isFalse);
    expect(c.state.photoError, contains('at least 3 photos'));
    expect(c.state.deletingPhotoId, isNull);
  });

  test('KYC submission goes to the backend and refreshes eligibility', () async {
    when(() => api.submitKyc(fullName: 'Asha Rao', docUrl: 'https://x/id.jpg', upiId: 'asha@upi'))
        .thenAnswer((_) async => 'pending');
    final c = build();

    final ok = await c.submitKyc(fullName: 'Asha Rao', docUrl: 'https://x/id.jpg', upiId: 'asha@upi');

    expect(ok, isTrue);
    expect(refreshes, 1);
    expect(c.state.kycError, isNull);
  });

  test('a refused KYC submission keeps the server error', () async {
    when(() => api.submitKyc(fullName: any(named: 'fullName'), docUrl: any(named: 'docUrl'), upiId: any(named: 'upiId')))
        .thenThrow(const ApiException(kind: ApiErrorKind.validation, code: 'photos_required', message: 'Add at least 3 profile photos'));
    final c = build();

    final ok = await c.submitKyc(fullName: 'A B', docUrl: 'https://x', upiId: 'a@b');

    expect(ok, isFalse);
    expect(c.state.kycError?.code, 'photos_required');
    expect(refreshes, 0);
  });
}
