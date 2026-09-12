import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/feed_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/features/feed/post_composer_controller.dart';
import 'package:moco/features/feed/post_composer_screen.dart';
import 'package:moco/shared/models/feed.dart';

import '../support/harness.dart';

class _MockFeedApi extends Mock implements FeedApi {}

class _MockDio extends Mock implements Dio {}

final _pickedImage = PickedMedia(
  bytes: Uint8List.fromList(List.filled(2048, 3)),
  fileName: 'holiday.jpg',
  mimeType: 'image/jpeg',
);

const _auth = PostUploadAuthorization(
  path: '7/holiday.jpg',
  uploadUrl: 'https://storage.example/upload/holiday',
  token: 'storage-token',
  mediaType: PostMediaType.image,
  maxBytes: 8 * 1024 * 1024,
  maxVideoSeconds: 60,
);

final _created = Post(
  id: 99,
  mediaType: PostMediaType.image,
  mediaUrl: 'https://storage.example/signed/holiday.jpg',
  createdAt: DateTime(2026, 2, 1, 10),
  author: const PostAuthor(id: 7, name: 'Me'),
);

void main() {
  late _MockFeedApi api;
  late _MockDio dio;
  late List<Override> base;

  setUpAll(() => registerFallbackValue(Options()));

  setUp(() async {
    api = _MockFeedApi();
    dio = _MockDio();
    base = await baseOverrides();
    // The feed underneath the composer loads too.
    when(() => api.feed()).thenAnswer((_) async => const FeedPage(posts: []));
  });

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

  Widget subject({PickedMedia? picks}) {
    return ProviderScope(
      overrides: [
        ...base,
        feedApiProvider.overrideWithValue(api),
        storageUploadClientProvider.overrideWithValue(dio),
        mediaPickerProvider.overrideWithValue(
          ({required bool video}) async => picks,
        ),
      ],
      child: MaterialApp(
        theme: MocoTheme.dark,
        home: const PostComposerScreen(),
      ),
    );
  }

  testWidgets('offers a photo and a video choice, with publish disabled', (tester) async {
    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_pick_image')), findsOneWidget);
    expect(find.byKey(const Key('composer_pick_video')), findsOneWidget);

    final button = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('composer_publish')),
        matching: find.byType(InkWell),
      ),
    );
    expect(button.onTap, isNull, reason: 'nothing to publish yet');
  });

  testWidgets('choosing media shows it and enables publish', (tester) async {
    await tester.pumpWidget(subject(picks: _pickedImage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_selected_name')), findsOneWidget);
    expect(find.text('holiday.jpg'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
  });

  testWidgets('cancelling the picker leaves the composer untouched', (tester) async {
    await tester.pumpWidget(subject(picks: null));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_selected_name')), findsNothing);
    expect(find.byKey(const Key('composer_pick_image')), findsOneWidget);
  });

  testWidgets('publishing uploads then creates the post and closes', (tester) async {
    when(() => api.requestUploadUrl('image/jpeg')).thenAnswer((_) async => _auth);
    stubUploadSuccess();
    when(
      () => api.createPost(
        mediaPath: '7/holiday.jpg',
        caption: 'from the hills',
      ),
    ).thenAnswer((_) async => _created);

    await tester.pumpWidget(subject(picks: _pickedImage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('composer_caption')),
      'from the hills',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('composer_publish')));
    await tester.pumpAndSettle();

    verify(
      () => api.createPost(
        mediaPath: '7/holiday.jpg',
        caption: 'from the hills',
      ),
    ).called(1);
  });

  testWidgets('a failed upload shows the error and offers a retry', (tester) async {
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

    await tester.pumpWidget(subject(picks: _pickedImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_publish')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_error')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // The chosen media survives, so retrying does not mean picking again.
    expect(find.text('holiday.jpg'), findsOneWidget);
    verifyNever(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    );
  });

  testWidgets('a rejected post reports the server message', (tester) async {
    when(() => api.requestUploadUrl(any())).thenAnswer((_) async => _auth);
    stubUploadSuccess();
    when(
      () => api.createPost(
        mediaPath: any(named: 'mediaPath'),
        caption: any(named: 'caption'),
      ),
    ).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        code: 'storage_not_configured',
        message: 'Posting is not available right now',
      ),
    );

    await tester.pumpWidget(subject(picks: _pickedImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_publish')));
    await tester.pumpAndSettle();

    expect(find.text('Posting is not available right now'), findsOneWidget);
  });

  testWidgets('progress is shown while the upload runs', (tester) async {
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
      (invocation.namedArguments[#onSendProgress] as void Function(int, int))(
        30,
        100,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
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

    await tester.pumpWidget(subject(picks: _pickedImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_publish')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('composer_progress')), findsOneWidget);
    expect(find.text('Uploading… 30%'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('removing the chosen media returns to the picker', (tester) async {
    await tester.pumpWidget(subject(picks: _pickedImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer_pick_image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('composer_clear_media')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_selected_name')), findsNothing);
    expect(find.byKey(const Key('composer_pick_image')), findsOneWidget);
  });
}
