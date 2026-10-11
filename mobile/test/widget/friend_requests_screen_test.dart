import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/friends_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/providers.dart';
import 'package:moco/core/widgets/moco_states.dart';
import 'package:moco/features/friends/friend_requests_screen.dart';

import '../support/harness.dart';

class _MockFriendsApi extends Mock implements FriendsApi {}

PendingFriendRequest _req(int id, {String name = 'Priya'}) => PendingFriendRequest(
  requestId: id,
  requesterName: name,
  requesterId: 100 + id,
  createdAt: '2026-01-01T00:00:00.000Z',
);

void main() {
  late _MockFriendsApi api;
  late List<Override> base;

  setUp(() async {
    api = _MockFriendsApi();
    base = await baseOverrides();
  });

  Widget subject() => wrapWidget(
    const FriendRequestsScreen(),
    overrides: [...base, friendsApiProvider.overrideWithValue(api)],
  );

  testWidgets('shows skeletons then the list', (tester) async {
    final completer = Completer<List<PendingFriendRequest>>();
    when(() => api.pendingRequests()).thenAnswer((_) => completer.future);

    await tester.pumpWidget(subject());
    await tester.pump();

    expect(find.byType(MocoSkeleton), findsWidgets);

    completer.complete([_req(1), _req(2, name: 'Arjun')]);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('friend_requests_list')), findsOneWidget);
    expect(find.byKey(const Key('friend_request_row_1')), findsOneWidget);
    expect(find.byKey(const Key('friend_request_row_2')), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
    expect(find.text('Arjun'), findsOneWidget);
  });

  testWidgets('shows the empty state', (tester) async {
    when(() => api.pendingRequests()).thenAnswer((_) async => const []);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('friend_requests_empty')), findsOneWidget);
    expect(find.text('No pending friend requests'), findsOneWidget);
  });

  testWidgets('shows an error and retry reloads', (tester) async {
    when(() => api.pendingRequests()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'No internet connection'),
    );

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('friend_requests_error')), findsOneWidget);

    when(() => api.pendingRequests()).thenAnswer((_) async => [_req(1)]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('friend_request_row_1')), findsOneWidget);
  });

  testWidgets('accepting removes the row and shows a snackbar', (tester) async {
    when(() => api.pendingRequests()).thenAnswer((_) async => [_req(1)]);
    when(() => api.respond(1, accept: true))
        .thenAnswer((_) async => const FriendRespondResult(requestId: 1, status: 'accepted'));

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('friend_request_accept_1')));
    await tester.pumpAndSettle();

    verify(() => api.respond(1, accept: true)).called(1);
    expect(find.byKey(const Key('friend_request_row_1')), findsNothing);
    expect(find.text('You and Priya are now friends'), findsOneWidget);
  });
}
