import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/theme/moco_theme.dart';
import 'package:moco/core/widgets/moco_surfaces.dart';
import 'package:moco/features/listener_application/listener_application_controller.dart';
import 'package:moco/features/listener_application/listener_application_screen.dart';
import 'package:moco/shared/models/listener_photos.dart';
import 'package:moco/shared/models/user.dart';

import '../support/harness.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

ListenerPhotos _photos(int n) => ListenerPhotos(
  photos: List.generate(n, (i) => ListenerPhoto(id: i + 1)),
);

MocoUser _user(ListenerState l) =>
    MocoUser(id: 7, phone: '+919800000007', displayName: 'Asha', role: 'both', listener: l);

void main() {
  late _MockListenersApi api;
  ({String name, Uint8List bytes})? nextPick;

  setUp(() {
    api = _MockListenersApi();
    nextPick = null;
  });

  Future<void> pump(WidgetTester tester, MocoUser user, {int photos = 0}) async {
    // Tall enough that the lazily built ListView includes the KYC section.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    when(() => api.myPhotos()).thenAnswer((_) async => _photos(photos));
    final overrides = await signedInOverrides(user: user);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          listenersApiProvider.overrideWithValue(api),
          listenerPhotoPickerProvider.overrideWithValue(() async => nextPick),
          photoUploaderProvider.overrideWithValue(({
            required String uploadUrl,
            required String token,
            required String mimeType,
            required Uint8List bytes,
            required void Function(double) onProgress,
          }) async {}),
        ],
        child: MaterialApp(theme: MocoTheme.dark(), home: const ListenerApplicationScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a draft listener sees exactly what blocks them, and cannot submit without photos', (tester) async {
    await pump(
      tester,
      _user(const ListenerState(kycStatus: 'unsubmitted', photoCount: 0, blockers: ['photos', 'kyc'])),
    );

    expect(find.text('Not ready to go online yet'), findsOneWidget);
    expect(find.text('Add 3 more profile photos (0 of 3 required)'), findsOneWidget);
    expect(find.text('Submit identity verification'), findsOneWidget);
    expect(find.byKey(const Key('kyc_status_unsubmitted')), findsOneWidget);
    expect(find.byKey(const Key('kyc_needs_photos')), findsOneWidget);

    final button = tester.widget<MocoPrimaryButton>(find.byKey(const Key('kyc_submit')));
    expect(button.onPressed, isNull, reason: 'submission is gated until 3 photos exist');
  });

  testWidgets('picking a photo uploads and registers it, updating the count', (tester) async {
    when(() => api.requestPhotoUploadUrl('image/jpeg')).thenAnswer(
      (_) async => const ListenerPhotoUploadAuthorization(path: '7/a.jpg', uploadUrl: 'u', token: 't', maxBytes: 8000000),
    );
    when(() => api.registerPhoto('7/a.jpg')).thenAnswer((_) async => _photos(1));
    await pump(tester, _user(const ListenerState(photoCount: 0, blockers: ['photos', 'kyc'])));

    nextPick = (name: 'me.jpg', bytes: Uint8List(100));
    await tester.tap(find.byKey(const Key('add_listener_photo')));
    await tester.pump();
    await tester.pump();

    verify(() => api.registerPhoto('7/a.jpg')).called(1);
    expect(find.text('1 of 3 required'), findsOneWidget);
  });

  testWidgets('a non-image pick is refused with a clear message and no request', (tester) async {
    await pump(tester, _user(const ListenerState(photoCount: 0, blockers: ['photos', 'kyc'])));

    nextPick = (name: 'notes.pdf', bytes: Uint8List(10));
    await tester.tap(find.byKey(const Key('add_listener_photo')));
    await tester.pump();

    expect(find.byKey(const Key('listener_photo_error')), findsOneWidget);
    verifyNever(() => api.requestPhotoUploadUrl(any()));
  });

  testWidgets('a rejected listener sees the reason and can resubmit', (tester) async {
    when(() => api.submitKyc(fullName: 'Asha Rao', docUrl: 'https://docs.example/id.jpg', upiId: 'asha@upi'))
        .thenAnswer((_) async => 'pending');
    await pump(
      tester,
      _user(const ListenerState(
        kycStatus: 'rejected',
        photoCount: 3,
        blockers: ['kyc'],
        kycRejectionReason: 'ID photo is blurry',
      )),
      photos: 3,
    );

    expect(find.text('Reason: ID photo is blurry'), findsOneWidget);
    expect(find.text('Verification was rejected — update and resubmit'), findsOneWidget);
    expect(find.byKey(const Key('kyc_needs_photos')), findsNothing);

    await tester.enterText(find.byKey(const Key('kyc_full_name')), 'Asha Rao');
    await tester.enterText(find.byKey(const Key('kyc_doc_url')), 'https://docs.example/id.jpg');
    await tester.enterText(find.byKey(const Key('kyc_upi')), 'asha@upi');
    expect(find.text('Resubmit for review'), findsOneWidget);
    await tester.tap(find.byKey(const Key('kyc_submit')));
    await tester.pump();

    verify(() => api.submitKyc(fullName: 'Asha Rao', docUrl: 'https://docs.example/id.jpg', upiId: 'asha@upi')).called(1);
  });

  testWidgets('invalid KYC fields are caught before any request', (tester) async {
    await pump(tester, _user(const ListenerState(photoCount: 3, blockers: ['kyc'])), photos: 3);

    await tester.enterText(find.byKey(const Key('kyc_full_name')), 'A');
    await tester.enterText(find.byKey(const Key('kyc_doc_url')), 'not a link');
    await tester.enterText(find.byKey(const Key('kyc_upi')), 'nope');
    await tester.tap(find.byKey(const Key('kyc_submit')));
    await tester.pump();

    expect(find.text('Enter a valid https:// link'), findsOneWidget);
    expect(find.text('Enter a UPI ID like name@bank'), findsOneWidget);
    verifyNever(() => api.submitKyc(fullName: any(named: 'fullName'), docUrl: any(named: 'docUrl'), upiId: any(named: 'upiId')));
  });

  testWidgets('a pending application shows its review state and no form', (tester) async {
    await pump(tester, _user(const ListenerState(kycStatus: 'pending', photoCount: 3, blockers: ['kyc'])), photos: 3);

    expect(find.byKey(const Key('kyc_status_pending')), findsOneWidget);
    expect(find.text('Verification is under review'), findsOneWidget);
    expect(find.byKey(const Key('kyc_submit')), findsNothing);
  });

  testWidgets('an eligible listener is told they can go online', (tester) async {
    await pump(tester, _user(const ListenerState(kycStatus: 'approved', photoCount: 3, blockers: [])), photos: 3);

    expect(find.text('You can go online and take calls'), findsOneWidget);
    expect(find.byKey(const Key('kyc_status_approved')), findsOneWidget);
  });
}
