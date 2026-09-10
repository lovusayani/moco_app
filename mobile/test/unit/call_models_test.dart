import 'package:flutter_test/flutter_test.dart';
import 'package:moco/shared/models/call.dart';

void main() {
  group('CallType/CallStatus/CallEndReason mapping', () {
    test('CallType falls back to audio for anything but "video"', () {
      expect(CallType.fromJson('video'), CallType.video);
      expect(CallType.fromJson('audio'), CallType.audio);
      expect(CallType.fromJson(null), CallType.audio);
      expect(CallType.fromJson('nonsense'), CallType.audio);
    });

    test('CallStatus falls back to ringing for an unrecognised value', () {
      expect(CallStatus.fromJson('active'), CallStatus.active);
      expect(CallStatus.fromJson('ended'), CallStatus.ended);
      expect(CallStatus.fromJson('failed'), CallStatus.failed);
      expect(CallStatus.fromJson('ringing'), CallStatus.ringing);
      expect(CallStatus.fromJson(null), CallStatus.ringing);
    });

    test('CallEndReason maps every backend CALL_END_REASON value', () {
      expect(CallEndReason.fromJson('caller_hangup'), CallEndReason.callerHangup);
      expect(CallEndReason.fromJson('listener_hangup'), CallEndReason.listenerHangup);
      expect(
        CallEndReason.fromJson('insufficient_balance'),
        CallEndReason.insufficientBalance,
      );
      expect(CallEndReason.fromJson('disconnect'), CallEndReason.disconnect);
      expect(CallEndReason.fromJson('rejected'), CallEndReason.rejected);
      expect(CallEndReason.fromJson('timeout'), CallEndReason.timeout);
      expect(CallEndReason.fromJson('admin'), CallEndReason.admin);
      expect(CallEndReason.fromJson('something_new'), CallEndReason.unknown);
    });
  });

  group('AgoraCredentials', () {
    test('isConfigured is false for an empty channel (dev, no Agora creds)', () {
      const creds = AgoraCredentials(channel: '', token: null, uid: 0);
      expect(creds.isConfigured, isFalse);
    });

    test('a null token is tolerated when the channel is real', () {
      final creds = AgoraCredentials.fromJson({
        'channel': 'moco_1_2',
        'token': null,
        'uid': 1,
      });
      expect(creds.isConfigured, isTrue);
      expect(creds.token, isNull);
    });
  });

  group('call:tick — caller vs listener are genuinely different shapes', () {
    test('CallerCallTick reads balance/minutesRemaining, not earned', () {
      final tick = CallerCallTick.fromJson({
        'callId': 1,
        'minuteIndex': 2,
        'coinsCharged': 6,
        'balance': 88,
        'minutesRemaining': 14,
      });
      expect(tick.balance, 88);
      expect(tick.minutesRemaining, 14);
      expect(tick.coinsCharged, 6);
    });

    test('ListenerCallTick reads only earned', () {
      final tick = ListenerCallTick.fromJson({
        'callId': 1,
        'minuteIndex': 2,
        'earned': 2,
      });
      expect(tick.earned, 2);
    });
  });

  group('call:forced_end — listener payload adds earned', () {
    test('CallerForcedEnd has no earned field', () {
      final forcedEnd = CallerForcedEnd.fromJson({
        'callId': 9,
        'reason': 'insufficient_balance',
        'billedMinutes': 3,
        'coinsSpent': 18,
      });
      expect(forcedEnd.reason, CallEndReason.insufficientBalance);
      expect(forcedEnd.billedMinutes, 3);
      expect(forcedEnd.coinsSpent, 18);
    });

    test('ListenerForcedEnd carries earned on top of the caller shape', () {
      final forcedEnd = ListenerForcedEnd.fromJson({
        'callId': 9,
        'reason': 'insufficient_balance',
        'billedMinutes': 3,
        'coinsSpent': 18,
        'earned': 6,
      });
      expect(forcedEnd.earned, 6);
      expect(forcedEnd.billedMinutes, 3);
    });
  });

  group('CallSummary — server-authoritative call-ended fields', () {
    test('parses the REST /calls/:id/end response shape (endReason)', () {
      final summary = CallSummary.fromJson({
        'callId': 4,
        'endReason': 'caller_hangup',
        'billedMinutes': 2,
        'coinsSpent': 12,
        'listenerEarned': 4,
        'durationSeconds': 95,
        'callerBalance': 88,
      });

      expect(summary.endReason, CallEndReason.callerHangup);
      expect(summary.billedMinutes, 2);
      expect(summary.coinsSpent, 12);
      expect(summary.listenerEarned, 4);
      expect(summary.durationSeconds, 95);
      expect(summary.callerBalance, 88);
    });

    test('parses the call:ended socket payload shape (reason + earned)', () {
      final summary = CallSummary.fromJson({
        'callId': 4,
        'reason': 'listener_hangup',
        'billedMinutes': 1,
        'coinsSpent': 6,
        'durationSeconds': 40,
        'earned': 2,
      });

      expect(summary.endReason, CallEndReason.listenerHangup);
      expect(summary.listenerEarned, 2);
    });

    test('callerBalance is null when the backend does not send it', () {
      final summary = CallSummary.fromJson({
        'callId': 4,
        'reason': 'rejected',
        'billedMinutes': 0,
        'coinsSpent': 0,
        'durationSeconds': 0,
      });
      expect(summary.callerBalance, isNull);
    });
  });

  group('IncomingCallEvent', () {
    test('derives the Agora uid from the caller id', () {
      final event = IncomingCallEvent.fromJson({
        'callId': 3,
        'callType': 'video',
        'caller': {'id': 11, 'name': 'Zoya'},
        'agoraChannel': 'moco_11_3',
        'agoraToken': 'tok',
      });

      expect(event.callType, CallType.video);
      expect(event.callerId, 11);
      expect(event.callerName, 'Zoya');
      expect(event.agora.uid, 11);
      expect(event.agora.channel, 'moco_11_3');
    });
  });
}
