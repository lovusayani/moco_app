import '../errors/api_exception.dart';
import '../../shared/models/call.dart';

/// Which side of the call this device is on. Decided once, when the call
/// starts (by who initiated it or who received `call:incoming`), and never
/// re-derived — a call cannot switch roles mid-flight.
enum CallRole { caller, listener }

/// The Flutter-only call lifecycle.
///
/// This is deliberately NOT [CallStatus]: the server only knows
/// ringing/active/ended/failed, but the UI also needs to represent purely
/// local moments (dialling, joining Agora, a locally-initiated hangup still in
/// flight) that the server has no notion of. Mapping is one-directional —
/// server events move this forward, never the other way around.
enum CallPhase {
  /// No call in progress.
  idle,

  /// Caller tapped a call CTA; `POST /calls/initiate` is in flight.
  initiating,

  /// Caller: the callee's phone is ringing (`call:incoming` was delivered,
  /// server status is `ringing`).
  ringing,

  /// Listener: `call:incoming` arrived and Accept/Decline is on screen.
  incoming,

  /// Server confirmed `active` (accept succeeded / `call:accepted` arrived);
  /// the Agora engine is joining the channel.
  connecting,

  /// Joined Agora and the call is live. Billing ticks may arrive at any point
  /// in this phase.
  active,

  /// A local end (button press or forced end) is being settled.
  ending,

  /// Settled normally; [CallSession.summary] holds the result to display.
  ended,

  /// The listener declined, or the callee's app declined on their behalf.
  rejected,

  /// The caller cancelled before the listener answered.
  cancelled,

  /// Could not even start (network, validation, listener no longer valid).
  failed,

  /// Pre-flight or a forced end reported the caller cannot fund the call.
  insufficientBalance,

  /// Socket dropped mid-call; server state is unknown until it reconnects.
  /// The call is NOT ended locally — only the server may end it.
  reconnecting,
}

/// Everything the call UI needs, in one immutable snapshot.
///
/// Nothing here is a billing decision: `balance`/`minutesRemaining`/`earned`
/// are display copies of the last server-sent figures, never computed.
class CallSession {
  const CallSession({
    this.phase = CallPhase.idle,
    this.role,
    this.callId,
    this.callType,
    this.counterpartyId,
    this.counterpartyName,
    this.counterpartyAvatarUrl,
    this.agora,
    this.ratePerMinute,
    this.freeSecondsGranted = 0,
    this.balance,
    this.minutesRemaining,
    this.lowBalance = false,
    this.earnedThisCall = 0,
    this.startedAt,
    this.summary,
    this.error,
    this.isBusy = false,
    this.remoteJoined = false,
  });

  final CallPhase phase;
  final CallRole? role;
  final int? callId;
  final CallType? callType;

  final int? counterpartyId;
  final String? counterpartyName;
  final String? counterpartyAvatarUrl;

  final AgoraCredentials? agora;
  final int? ratePerMinute;
  final int freeSecondsGranted;

  /// Caller-only: last balance the server reported (initiate response or a
  /// `call:tick`/`call:forced_end`/`call:ended` payload).
  final int? balance;
  final int? minutesRemaining;
  final bool lowBalance;

  /// Listener-only: running display total of `earned` across ticks this call.
  /// Purely a sum of numbers the server already credited — not a projection.
  final int earnedThisCall;

  /// Display-only anchor for the elapsed-time counter. Never used for billing.
  final DateTime? startedAt;

  final CallSummary? summary;
  final ApiException? error;

  /// True while an initiate/accept/decline/end request is in flight, so a
  /// second tap cannot fire a duplicate action.
  final bool isBusy;

  /// Whether the remote party's media has joined the Agora channel.
  final bool remoteJoined;

  bool get isInCall => phase == CallPhase.connecting || phase == CallPhase.active;
  bool get isTerminal => switch (phase) {
    CallPhase.ended ||
    CallPhase.rejected ||
    CallPhase.cancelled ||
    CallPhase.failed ||
    CallPhase.insufficientBalance => true,
    _ => false,
  };

  CallSession copyWith({
    CallPhase? phase,
    CallRole? role,
    int? callId,
    CallType? callType,
    int? counterpartyId,
    String? counterpartyName,
    String? counterpartyAvatarUrl,
    AgoraCredentials? agora,
    int? ratePerMinute,
    int? freeSecondsGranted,
    int? balance,
    int? minutesRemaining,
    bool? lowBalance,
    int? earnedThisCall,
    DateTime? startedAt,
    CallSummary? summary,
    ApiException? error,
    bool? isBusy,
    bool? remoteJoined,
    bool clearError = false,
  }) {
    return CallSession(
      phase: phase ?? this.phase,
      role: role ?? this.role,
      callId: callId ?? this.callId,
      callType: callType ?? this.callType,
      counterpartyId: counterpartyId ?? this.counterpartyId,
      counterpartyName: counterpartyName ?? this.counterpartyName,
      counterpartyAvatarUrl: counterpartyAvatarUrl ?? this.counterpartyAvatarUrl,
      agora: agora ?? this.agora,
      ratePerMinute: ratePerMinute ?? this.ratePerMinute,
      freeSecondsGranted: freeSecondsGranted ?? this.freeSecondsGranted,
      balance: balance ?? this.balance,
      minutesRemaining: minutesRemaining ?? this.minutesRemaining,
      lowBalance: lowBalance ?? this.lowBalance,
      earnedThisCall: earnedThisCall ?? this.earnedThisCall,
      startedAt: startedAt ?? this.startedAt,
      summary: summary ?? this.summary,
      error: clearError ? null : (error ?? this.error),
      isBusy: isBusy ?? this.isBusy,
      remoteJoined: remoteJoined ?? this.remoteJoined,
    );
  }
}
