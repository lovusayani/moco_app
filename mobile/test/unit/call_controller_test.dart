import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/calls_api.dart';
import 'package:moco/core/calling/agora_call_service.dart';
import 'package:moco/core/calling/call_controller.dart';
import 'package:moco/core/calling/call_session.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/core/realtime/socket_service.dart';
import 'package:moco/shared/models/call.dart';
import 'package:moco/shared/models/listener.dart';

class _MockCallsApi extends Mock implements CallsApi {}

class _MockSocketService extends Mock implements SocketService {}

class _MockAgoraCallService extends Mock implements AgoraCallService {}

const _listener = ListenerDetail(
  id: 7,
  displayName: 'Priya',
  audioRate: 6,
  videoRate: 12,
);

const _configuredCredentials = AgoraCredentials(
  channel: 'moco_7_1',
  token: 'tok',
  uid: 1,
);

const _unconfiguredCredentials = AgoraCredentials(channel: '', token: null, uid: 0);

void main() {
  setUpAll(() {
    registerFallbackValue(CallType.audio);
    registerFallbackValue(_configuredCredentials);
    registerFallbackValue(CallEndReason.rejected);
  });

  late _MockCallsApi callsApi;
  late _MockSocketService socket;
  late _MockAgoraCallService agora;
  late Map<String, void Function(dynamic)> handlers;
  late ValueNotifier<SocketStatus> socketStatus;
  late ValueNotifier<RtcConnectionStatus> agoraConnectionStatus;
  late ValueNotifier<bool> agoraRemoteJoined;
  late CallController controller;

  void emit(String event, Map<String, dynamic> payload) {
    handlers[event]?.call(payload);
  }

  setUp(() {
    callsApi = _MockCallsApi();
    socket = _MockSocketService();
    agora = _MockAgoraCallService();
    handlers = {};
    socketStatus = ValueNotifier(SocketStatus.connected);
    agoraConnectionStatus = ValueNotifier(RtcConnectionStatus.disconnected);
    agoraRemoteJoined = ValueNotifier(false);

    when(() => socket.status).thenReturn(socketStatus);
    when(() => socket.on(any(), any())).thenAnswer((invocation) {
      final event = invocation.positionalArguments[0] as String;
      final handler =
          invocation.positionalArguments[1] as void Function(dynamic);
      handlers[event] = handler;
      return () {};
    });

    when(() => agora.connectionStatus).thenReturn(agoraConnectionStatus);
    when(() => agora.remoteJoined).thenReturn(agoraRemoteJoined);
    when(() => agora.join(credentials: any(named: 'credentials'), type: any(named: 'type')))
        .thenAnswer((_) async {});
    when(() => agora.leave()).thenAnswer((_) async {});

    controller = CallController(callsApi: callsApi, socket: socket, agora: agora);
  });

  tearDown(() {
    controller.dispose();
  });

  group('initiateCall (caller)', () {
    test('success moves idle -> initiating -> ringing with server data', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenAnswer(
        (_) async => const CallInitiation(
          callId: 42,
          status: CallStatus.ringing,
          agora: _configuredCredentials,
          ratePerMinute: 6,
          freeSeconds: 60,
          balance: 100,
        ),
      );

      final future = controller.initiateCall(listener: _listener, type: CallType.audio);
      expect(controller.state.phase, CallPhase.initiating);

      await future;

      expect(controller.state.phase, CallPhase.ringing);
      expect(controller.state.callId, 42);
      expect(controller.state.role, CallRole.caller);
      expect(controller.state.ratePerMinute, 6);
      expect(controller.state.freeSecondsGranted, 60);
      expect(controller.state.balance, 100);
      expect(controller.state.isBusy, isFalse);
    });

    test('insufficient balance maps to CallPhase.insufficientBalance', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenThrow(
        const ApiException(
          kind: ApiErrorKind.insufficientBalance,
          message: 'not enough coins',
        ),
      );

      await controller.initiateCall(listener: _listener, type: CallType.audio);

      expect(controller.state.phase, CallPhase.insufficientBalance);
      expect(controller.state.error, isNotNull);
    });

    test('listener_unavailable (conflict) maps to CallPhase.failed', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenThrow(
        const ApiException(kind: ApiErrorKind.conflict, message: 'busy'),
      );

      await controller.initiateCall(listener: _listener, type: CallType.audio);

      expect(controller.state.phase, CallPhase.failed);
    });

    test('a second call cannot be started while one is in progress', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenAnswer(
        (_) async => const CallInitiation(
          callId: 1,
          status: CallStatus.ringing,
          agora: _configuredCredentials,
          ratePerMinute: 6,
          freeSeconds: 0,
          balance: 50,
        ),
      );

      await controller.initiateCall(listener: _listener, type: CallType.audio);
      await controller.initiateCall(listener: _listener, type: CallType.video);

      verify(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).called(1);
      verifyNever(() => callsApi.initiate(listenerId: 7, type: CallType.video));
    });
  });

  group('call:accepted (caller side) and heartbeat', () {
    Future<void> ring() async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenAnswer(
        (_) async => const CallInitiation(
          callId: 42,
          status: CallStatus.ringing,
          agora: _configuredCredentials,
          ratePerMinute: 6,
          freeSeconds: 0,
          balance: 100,
        ),
      );
      await controller.initiateCall(listener: _listener, type: CallType.audio);
    }

    test('starts the heartbeat and advances to connecting', () async {
      await ring();
      expect(controller.debugHeartbeatActive, isFalse);

      emit('call:accepted', {'callId': 42, 'startedAt': null, 'freeSeconds': 0});
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, CallPhase.connecting);
      expect(controller.debugHeartbeatActive, isTrue);
      // A Map literal compares by identity, not content, so match on shape.
      verify(
        () => socket.emit('heartbeat', any(that: equals({'callId': 42}))),
      ).called(1);
    });

    test('advances straight to active when Agora is not configured (dev mode)', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenAnswer(
        (_) async => const CallInitiation(
          callId: 42,
          status: CallStatus.ringing,
          agora: _unconfiguredCredentials,
          ratePerMinute: 6,
          freeSeconds: 0,
          balance: 100,
        ),
      );
      await controller.initiateCall(listener: _listener, type: CallType.audio);

      emit('call:accepted', {'callId': 42});
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, CallPhase.active);
    });

    test('becomes active once Agora reports connected', () async {
      await ring();
      emit('call:accepted', {'callId': 42});
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, CallPhase.connecting);

      agoraConnectionStatus.value = RtcConnectionStatus.connected;

      expect(controller.state.phase, CallPhase.active);
    });

    test('a mismatched callId is ignored', () async {
      await ring();
      emit('call:accepted', {'callId': 999});
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, CallPhase.ringing);
    });
  });

  group('incoming call (listener side)', () {
    stubRejectEnd() => when(() => callsApi.end(any(), reason: any(named: 'reason')))
        .thenAnswer(
      (_) async => const CallSummary(
        callId: 5,
        endReason: CallEndReason.rejected,
        billedMinutes: 0,
        coinsSpent: 0,
        durationSeconds: 0,
      ),
    );

    test('call:incoming moves idle -> incoming', () {
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
        'agoraChannel': 'moco_3_5',
        'agoraToken': 'tok',
      });

      expect(controller.state.phase, CallPhase.incoming);
      expect(controller.state.role, CallRole.listener);
      expect(controller.state.callId, 5);
      expect(controller.state.counterpartyName, 'Aman');
    });

    test('a duplicate call:incoming while already handling one is ignored', () {
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
      });
      emit('call:incoming', {
        'callId': 6,
        'callType': 'video',
        'caller': {'id': 9, 'name': 'Someone else'},
      });

      // The first call wins; a reconnect redelivery or a genuinely new ring
      // must not clobber a call already on screen.
      expect(controller.state.callId, 5);
      expect(controller.state.callType, CallType.audio);
    });

    test('declineCall ends the call as rejected', () async {
      stubRejectEnd();
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
      });

      await controller.declineCall();

      verify(() => callsApi.end(5, reason: CallEndReason.rejected)).called(1);
      expect(controller.state.phase, CallPhase.rejected);
    });

    test('acceptCall cannot be double-tapped', () async {
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
      });

      final gate = <Completer<CallAcceptResult>>[];
      when(() => callsApi.accept(5)).thenAnswer((_) {
        final completer = Completer<CallAcceptResult>();
        gate.add(completer);
        return completer.future;
      });

      final first = controller.acceptCall();
      final second = controller.acceptCall(); // should be a no-op: still busy

      gate.single.complete(
        const CallAcceptResult(
          callId: 5,
          status: CallStatus.active,
          startedAt: null,
          agora: _configuredCredentials,
        ),
      );
      await first;
      await second;

      verify(() => callsApi.accept(5)).called(1);
    });
  });

  group('call:tick — distinct caller/listener payload shapes', () {
    test('caller tick updates balance and minutesRemaining', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenAnswer(
        (_) async => const CallInitiation(
          callId: 42,
          status: CallStatus.ringing,
          agora: _configuredCredentials,
          ratePerMinute: 6,
          freeSeconds: 0,
          balance: 100,
        ),
      );
      await controller.initiateCall(listener: _listener, type: CallType.audio);
      emit('call:accepted', {'callId': 42});
      await Future<void>.delayed(Duration.zero);

      emit('call:tick', {
        'callId': 42,
        'minuteIndex': 1,
        'coinsCharged': 6,
        'balance': 94,
        'minutesRemaining': 15,
      });

      expect(controller.state.balance, 94);
      expect(controller.state.minutesRemaining, 15);
      expect(controller.state.earnedThisCall, 0);
    });

    test('listener tick accumulates earnedThisCall from `earned` only', () {
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
      });
      // Simulate the server side already being active for this test.
      emit('call:tick', {'callId': 5, 'minuteIndex': 1, 'earned': 2});
      emit('call:tick', {'callId': 5, 'minuteIndex': 2, 'earned': 2});

      expect(controller.state.earnedThisCall, 4);
      expect(controller.state.balance, isNull);
    });
  });

  group('forced end vs local end race', () {
    test('forced_end wins when it arrives before the local end request settles', () async {
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
      });
      when(() => callsApi.accept(5)).thenAnswer(
        (_) async => const CallAcceptResult(
          callId: 5,
          status: CallStatus.active,
          startedAt: null,
          agora: _configuredCredentials,
        ),
      );
      await controller.acceptCall();
      agoraConnectionStatus.value = RtcConnectionStatus.connected;
      expect(controller.state.phase, CallPhase.active);

      final endCompleter = Completer<CallSummary>();
      when(() => callsApi.end(5, reason: null)).thenAnswer((_) => endCompleter.future);

      final endFuture = controller.endCall(); // in flight, not yet resolved
      expect(controller.state.phase, CallPhase.ending);

      // The server settles the call by force before our own end() resolves.
      emit('call:forced_end', {
        'callId': 5,
        'reason': 'insufficient_balance',
        'billedMinutes': 2,
        'coinsSpent': 12,
      });

      expect(controller.state.phase, CallPhase.insufficientBalance);
      expect(controller.debugHeartbeatActive, isFalse);

      // The delayed local end() response must not overwrite the forced result.
      endCompleter.complete(
        const CallSummary(
          callId: 5,
          endReason: CallEndReason.listenerHangup,
          billedMinutes: 1,
          coinsSpent: 6,
          durationSeconds: 30,
        ),
      );
      await endFuture;

      expect(controller.state.phase, CallPhase.insufficientBalance);
      expect(controller.state.summary?.billedMinutes, 2);
    });
  });

  group('cancelOutgoing', () {
    test('cancelling before answer settles with no summary', () async {
      when(() => callsApi.initiate(listenerId: 7, type: CallType.audio)).thenAnswer(
        (_) async => const CallInitiation(
          callId: 42,
          status: CallStatus.ringing,
          agora: _configuredCredentials,
          ratePerMinute: 6,
          freeSeconds: 0,
          balance: 100,
        ),
      );
      await controller.initiateCall(listener: _listener, type: CallType.audio);

      when(() => callsApi.end(42, reason: null)).thenAnswer(
        (_) async => const CallSummary(
          callId: 42,
          endReason: CallEndReason.rejected,
          billedMinutes: 0,
          coinsSpent: 0,
          durationSeconds: 0,
        ),
      );

      await controller.cancelOutgoing();

      expect(controller.state.phase, CallPhase.cancelled);
      expect(controller.state.summary?.billedMinutes, 0);
    });
  });

  group('reset', () {
    test('returns to a clean idle session', () async {
      emit('call:incoming', {
        'callId': 5,
        'callType': 'audio',
        'caller': {'id': 3, 'name': 'Aman'},
      });
      when(() => callsApi.end(5, reason: CallEndReason.rejected)).thenAnswer(
        (_) async => const CallSummary(
          callId: 5,
          endReason: CallEndReason.rejected,
          billedMinutes: 0,
          coinsSpent: 0,
          durationSeconds: 0,
        ),
      );
      await controller.declineCall();
      expect(controller.state.phase, CallPhase.rejected);

      controller.reset();

      expect(controller.state.phase, CallPhase.idle);
      expect(controller.state.callId, isNull);

      // A fresh incoming call is accepted normally after a reset.
      emit('call:incoming', {
        'callId': 6,
        'callType': 'video',
        'caller': {'id': 4, 'name': 'Zoya'},
      });
      expect(controller.state.phase, CallPhase.incoming);
      expect(controller.state.callId, 6);
    });
  });
}
