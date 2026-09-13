import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/safety_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/features/safety/safety_actions_sheet.dart';

class _MockSafetyApi extends Mock implements SafetyApi {}

void main() {
  late _MockSafetyApi safetyApi;

  setUp(() {
    safetyApi = _MockSafetyApi();
  });

  Widget subject() {
    return ProviderScope(
      overrides: [safetyApiProvider.overrideWithValue(safetyApi)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) => ElevatedButton(
                  onPressed: () => showSafetyActionsSheet(
                    context: context,
                    ref: ref,
                    userId: 7,
                    userName: 'Priya',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('offers report and block for the named user', (tester) async {
    await tester.pumpWidget(subject());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Report Priya'), findsOneWidget);
    expect(find.text('Block Priya'), findsOneWidget);
  });

  testWidgets('blocking calls the backend with the given user id', (tester) async {
    when(() => safetyApi.block(7)).thenAnswer((_) async {});

    await tester.pumpWidget(subject());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('safety_action_block')));
    await tester.pumpAndSettle();

    verify(() => safetyApi.block(7)).called(1);
  });

  testWidgets('a failed block shows the error', (tester) async {
    when(() => safetyApi.block(7)).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'No internet connection'),
    );

    await tester.pumpWidget(subject());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('safety_action_block')));
    await tester.pumpAndSettle();

    expect(find.text('No internet connection'), findsOneWidget);
  });

  testWidgets('reporting asks for a reason, then submits it', (tester) async {
    when(() => safetyApi.report(userId: 7, reason: 'spam', callId: null))
        .thenAnswer((_) async {});

    await tester.pumpWidget(subject());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('safety_action_report')));
    await tester.pumpAndSettle();

    expect(find.text('Why are you reporting this?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('report_reason_spam')));
    await tester.pumpAndSettle();

    verify(() => safetyApi.report(userId: 7, reason: 'spam', callId: null)).called(1);
  });

  testWidgets('a call id, when given, is forwarded to the report', (tester) async {
    when(() => safetyApi.report(userId: 7, reason: 'harassment', callId: 42))
        .thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [safetyApiProvider.overrideWithValue(safetyApi)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ElevatedButton(
                  onPressed: () => showSafetyActionsSheet(
                    context: context,
                    ref: ref,
                    userId: 7,
                    userName: 'Priya',
                    callId: 42,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('safety_action_report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('report_reason_harassment')));
    await tester.pumpAndSettle();

    verify(() => safetyApi.report(userId: 7, reason: 'harassment', callId: 42)).called(1);
  });
}
