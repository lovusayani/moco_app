import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/friends_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/friends/friend_requests_controller.dart';

class _MockFriendsApi extends Mock implements FriendsApi {}

PendingFriendRequest _req(int id, {String name = 'Priya'}) => PendingFriendRequest(
  requestId: id,
  requesterName: name,
  requesterId: 100 + id,
  createdAt: '2026-01-01T00:00:00.000Z',
);

void main() {
  late _MockFriendsApi api;

  setUp(() {
    api = _MockFriendsApi();
  });

  Future<FriendRequestsController> loaded(List<PendingFriendRequest> requests) async {
    when(() => api.pendingRequests()).thenAnswer((_) async => requests);
    final controller = FriendRequestsController(api);
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  test('loads pending requests', () async {
    final controller = await loaded([_req(1), _req(2, name: 'Arjun')]);

    expect(controller.state.requests.map((r) => r.requestId), [1, 2]);
    expect(controller.state.isLoading, isFalse);
    expect(controller.state.error, isNull);
  });

  test('a failed load is fatal', () async {
    when(() => api.pendingRequests()).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );
    final controller = FriendRequestsController(api);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.isFatalError, isTrue);
    expect(controller.state.isLoading, isFalse);
  });

  test('accept removes the row and returns the friend message', () async {
    final controller = await loaded([_req(1), _req(2, name: 'Arjun')]);
    when(() => api.respond(1, accept: true))
        .thenAnswer((_) async => const FriendRespondResult(requestId: 1, status: 'accepted'));

    final outcome = await controller.respond(1, accept: true);

    expect(outcome.kind, RespondOutcomeKind.accepted);
    expect(outcome.message, 'You and Priya are now friends');
    expect(controller.state.requests.map((r) => r.requestId), [2]);
    expect(controller.state.busyIds, isEmpty);
  });

  test('reject removes the row and returns Request declined', () async {
    final controller = await loaded([_req(1)]);
    when(() => api.respond(1, accept: false))
        .thenAnswer((_) async => const FriendRespondResult(requestId: 1, status: 'rejected'));

    final outcome = await controller.respond(1, accept: false);

    expect(outcome.kind, RespondOutcomeKind.declined);
    expect(outcome.message, 'Request declined');
    expect(controller.state.requests, isEmpty);
    expect(controller.state.isEmpty, isTrue);
  });

  test('already_responded removes the row as gone', () async {
    final controller = await loaded([_req(1)]);
    when(() => api.respond(1, accept: true)).thenThrow(
      const ApiException(
        kind: ApiErrorKind.validation,
        message: 'This request has already been responded to',
        code: 'already_responded',
        statusCode: 400,
      ),
    );

    final outcome = await controller.respond(1, accept: true);

    expect(outcome.kind, RespondOutcomeKind.gone);
    expect(outcome.message, 'This request is no longer pending');
    expect(controller.state.requests, isEmpty);
    expect(controller.state.busyIds, isEmpty);
  });

  test('a 404 removes the row as gone', () async {
    final controller = await loaded([_req(1)]);
    when(() => api.respond(1, accept: true)).thenThrow(
      const ApiException(kind: ApiErrorKind.notFound, message: 'Not found', statusCode: 404),
    );

    final outcome = await controller.respond(1, accept: true);

    expect(outcome.kind, RespondOutcomeKind.gone);
    expect(outcome.message, 'This request is no longer pending');
    expect(controller.state.requests, isEmpty);
  });

  test('a 403 removes the row and uses the server message', () async {
    final controller = await loaded([_req(1)]);
    when(() => api.respond(1, accept: true)).thenThrow(
      const ApiException(
        kind: ApiErrorKind.forbidden,
        message: 'This user is not available',
        statusCode: 403,
      ),
    );

    final outcome = await controller.respond(1, accept: true);

    expect(outcome.kind, RespondOutcomeKind.gone);
    expect(outcome.message, 'This user is not available');
    expect(controller.state.requests, isEmpty);
  });

  test('any other error keeps the row and clears busy', () async {
    final controller = await loaded([_req(1)]);
    when(() => api.respond(1, accept: true)).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'No internet connection'),
    );

    final outcome = await controller.respond(1, accept: true);

    expect(outcome.kind, RespondOutcomeKind.failed);
    expect(outcome.message, 'No internet connection');
    expect(controller.state.requests.map((r) => r.requestId), [1]);
    expect(controller.state.busyIds, isEmpty);
  });

  test('a second tap while busy is ignored', () async {
    final controller = await loaded([_req(1)]);
    final completer = Completer<FriendRespondResult>();
    when(() => api.respond(1, accept: true)).thenAnswer((_) => completer.future);

    final first = controller.respond(1, accept: true);
    expect(controller.state.busyIds, {1});

    final second = await controller.respond(1, accept: true);
    expect(second.kind, RespondOutcomeKind.ignored);

    completer.complete(const FriendRespondResult(requestId: 1, status: 'accepted'));
    expect((await first).kind, RespondOutcomeKind.accepted);
    verify(() => api.respond(1, accept: true)).called(1);
  });
}
