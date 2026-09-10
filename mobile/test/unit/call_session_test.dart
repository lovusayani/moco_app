import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/calling/call_session.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/shared/models/call.dart';

void main() {
  group('CallSession derived state', () {
    test('idle is neither in-call nor terminal', () {
      const session = CallSession();
      expect(session.isInCall, isFalse);
      expect(session.isTerminal, isFalse);
    });

    test('connecting and active both count as in-call', () {
      const connecting = CallSession(phase: CallPhase.connecting);
      const active = CallSession(phase: CallPhase.active);
      expect(connecting.isInCall, isTrue);
      expect(active.isInCall, isTrue);
    });

    test('ringing and incoming are not yet in-call', () {
      const ringing = CallSession(phase: CallPhase.ringing);
      const incoming = CallSession(phase: CallPhase.incoming);
      expect(ringing.isInCall, isFalse);
      expect(incoming.isInCall, isFalse);
    });

    test('every terminal phase reports isTerminal', () {
      for (final phase in [
        CallPhase.ended,
        CallPhase.rejected,
        CallPhase.cancelled,
        CallPhase.failed,
        CallPhase.insufficientBalance,
      ]) {
        expect(CallSession(phase: phase).isTerminal, isTrue, reason: phase.name);
      }
    });

    test('reconnecting is not terminal — only the server ends a call', () {
      const session = CallSession(phase: CallPhase.reconnecting);
      expect(session.isTerminal, isFalse);
    });
  });

  group('CallSession.copyWith', () {
    test('preserves fields that are not overridden', () {
      const original = CallSession(
        phase: CallPhase.active,
        role: CallRole.caller,
        callId: 7,
        callType: CallType.audio,
        balance: 90,
      );

      final updated = original.copyWith(balance: 84);

      expect(updated.phase, CallPhase.active);
      expect(updated.callId, 7);
      expect(updated.balance, 84);
    });

    test('clearError actually clears rather than requiring a new error', () {
      const original = CallSession();
      final withError = original.copyWith(
        error: const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      final cleared = withError.copyWith(clearError: true);

      expect(withError.error, isNotNull);
      expect(cleared.error, isNull);
    });
  });
}
