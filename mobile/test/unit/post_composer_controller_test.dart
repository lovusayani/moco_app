import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/feed/post_composer_controller.dart';
import 'package:moco/shared/models/feed.dart';

class _MockFeedApi extends Mock implements FeedApi {}

class _MockDio extends Mock implements Dio {}

final _bytes = Uint8List.fromList(List.filled(1024, 7));

const _auth = PostUploadAuthorization(
  path: '7/abc.jpg',
  uploadUrl: 'https://storage.example/upload/abc',
  token: 'storage-token',
  mediaType: PostMediaType.image,
  maxBytes: 8 * 1024 * 1024,
  maxVideoSeconds: 60,
);

final _created = Post(
  id: 42,
  mediaType: PostMediaType.image,
  mediaUrl: 'https://storage.example/signed/abc.jpg',
  caption: 'hello',
  createdAt: DateTime(2026, 2, 1, 10),
  author: const PostAuthor(id: 7, name: 'Me'),
);

void main() {
  late _MockFeedApi api;
  late _MockDio dio;

  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(Uri.parse('https://storage.example'));
  });

  setUp(() {
    api = _MockFeedApi();
    dio = _MockDio();
  });

  PostComposerController subject() =>
      PostComposerController(api, uploadClient: dio);

  void stubUploadSuccess() {
    when(
      () => dio.put<dynamic>(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 200,
      ),
    );
  }

  void pick(PostComposerController controller, {String mimeType = 'image/jpeg'}) {
    controller.pickedMedia(
      bytes: _bytes,
      fileName: 'photo.jpg',
      mimeType: mimeType,
    );
  }

  test('nothing can be published before media is chosen', () async {
    final controller = subject();

    expect(controller.state.canPublish, isFalse);
    expect(await controller.publish(), isNull);
    verifyNever(() => api.requestUploadUrl(any()));
    controller.dispose();
  });

  test('choosing media enables publish and records its type', () {
    final controller = subject();

    pick(controller, mimeType: 'video/mp4');

    expect(controller.state.hasMedia, isTrue);
    expect(controller.state.canPublish, isTrue);
    expect(controller.state.isVideo, isTrue);
    controller.dispose();
  });

  test('a successful publish authorizes, uploads, then saves the post', () async {
    when(() => api.requestUploadUrl('image/jpeg')).thenAnswer((_) async => _auth);
    stubUploadSuccess();
    when(
      () => api.createPost(mediaPath: '7/abc.jpg', caption: 'hello'),
    ).thenAnswer((_) async => _created);

    final controller = subject();
    pick(controller);
    controller.captionChanged('hello');

    final post = await controller.publish();

    expect(post?.id, 42);
    expect(controller.state.stage, PublishStage.done);
    expect(controller.state.published?.id, 42);
    expect(controller.state.error, isNull);

    // The order matters: a post must not exist before its media does.
    verifyInOrder([
      () => api.requestUploadUrl('image/jpeg'),
      () => api.createPost(mediaPath: '7/abc.jpg', caption: 'hello'),
    ]);
    controller.dispose();
  });

  test('the upload carries the storage token, not the app session', () async {
    when(() => api.requestUploadUrl(any())).thenAnswer((_) async => _auth);
    stubUploadSuccess();
    when(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    ).thenAnswer((_) async => _created);

    final controller = subject();
    pick(controller);
    await controller.publish();

    final captured = verify(
      () => dio.put<dynamic>(
        _auth.uploadUrl,
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        options: captureAny(named: 'options'),
      ),
    ).captured.single as Options;

    expect(captured.headers?['Authorization'], 'Bearer storage-token');
    expect(captured.headers?['Content-Type'], 'image/jpeg');
    controller.dispose();
  });

  test('a failed upload surfaces an error and creates no post', () async {
    when(() => api.requestUploadUrl(any())).thenAnswer((_) async => _auth);
    when(
      () => dio.put<dynamic>(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        options: any(named: 'options'),
      ),
    ).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      ),
    );

    final controller = subject();
    pick(controller);

    final post = await controller.publish();

    expect(post, isNull);
    expect(controller.state.error, isNotNull);
    expect(controller.state.stage, PublishStage.idle);
    verifyNever(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    );
    // The chosen media survives, so Retry is one tap.
    expect(controller.state.hasMedia, isTrue);
    expect(controller.state.canPublish, isTrue);
    controller.dispose();
  });

  test('a rejected post leaves an error even though the upload succeeded', () async {
    when(() => api.requestUploadUrl(any())).thenAnswer((_) async => _auth);
    stubUploadSuccess();
    when(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.forbidden,
        message: 'This media does not belong to you',
      ),
    );

    final controller = subject();
    pick(controller);

    expect(await controller.publish(), isNull);
    expect(controller.state.error?.message, 'This media does not belong to you');
    expect(controller.state.published, isNull);
    controller.dispose();
  });

  test('media larger than the server cap is refused before uploading', () async {
    when(() => api.requestUploadUrl(any())).thenAnswer(
      (_) async => const PostUploadAuthorization(
        path: '7/abc.jpg',
        uploadUrl: 'https://storage.example/upload/abc',
        token: 'storage-token',
        mediaType: PostMediaType.image,
        maxBytes: 10,
        maxVideoSeconds: 60,
      ),
    );

    final controller = subject();
    pick(controller);

    expect(await controller.publish(), isNull);
    expect(controller.state.error, isNotNull);
    verifyNever(
      () => dio.put<dynamic>(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        options: any(named: 'options'),
      ),
    );
    controller.dispose();
  });

  test('a failed authorization never reaches the upload', () async {
    when(() => api.requestUploadUrl(any())).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        code: 'storage_not_configured',
        message: 'Posting is not available right now',
      ),
    );

    final controller = subject();
    pick(controller);

    expect(await controller.publish(), isNull);
    expect(controller.state.error?.code, 'storage_not_configured');
    verifyNever(
      () => dio.put<dynamic>(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        options: any(named: 'options'),
      ),
    );
    controller.dispose();
  });

  test('upload progress is reported from the real transfer', () async {
    when(() => api.requestUploadUrl(any())).thenAnswer((_) async => _auth);
    when(
      () => dio.put<dynamic>(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        options: any(named: 'options'),
      ),
    ).thenAnswer((invocation) async {
      final onSendProgress =
          invocation.namedArguments[#onSendProgress] as void Function(int, int);
      onSendProgress(512, 1024);
      return Response<dynamic>(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 200,
      );
    });
    when(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    ).thenAnswer((_) async => _created);

    final controller = subject();
    pick(controller);

    final progressSeen = <double>[];
    controller.addListener((s) {
      if (s.stage == PublishStage.uploading) progressSeen.add(s.uploadProgress);
    });

    await controller.publish();

    expect(progressSeen, contains(0.5));
    controller.dispose();
  });

  test('a second publish is ignored while one is in flight', () async {
    when(() => api.requestUploadUrl(any())).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return _auth;
    });
    stubUploadSuccess();
    when(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    ).thenAnswer((_) async => _created);

    final controller = subject();
    pick(controller);

    await Future.wait([controller.publish(), controller.publish()]);

    verify(() => api.requestUploadUrl(any())).called(1);
    controller.dispose();
  });

  test('clearing media resets the composer but keeps the caption', () {
    final controller = subject();
    pick(controller);
    controller.captionChanged('a caption');

    controller.clearMedia();

    expect(controller.state.hasMedia, isFalse);
    expect(controller.state.canPublish, isFalse);
    expect(controller.state.caption, 'a caption');
    controller.dispose();
  });
}
