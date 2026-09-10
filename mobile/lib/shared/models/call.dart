/// Call domain models — one typed shape per backend response/event, matching
/// docs/API.md exactly. The server is the only source of truth for status,
/// rates and billing; nothing here recomputes what it is told.
library;

/// Mirrors `CALL_TYPE` in constants.js.
enum CallType {
  audio,
  video;

  static CallType fromJson(String? value) =>
      value == 'video' ? CallType.video : CallType.audio;

  String toJson() => name;
}

/// Mirrors `CALL_STATUS` in constants.js. This is the server's status only —
/// client-only transitions (initiating, connecting, cancelled…) live on
/// [CallPhase], not here, so the two are never confused.
enum CallStatus {
  ringing,
  active,
  ended,
  failed;

  static CallStatus fromJson(String? value) => switch (value) {
    'active' => CallStatus.active,
    'ended' => CallStatus.ended,
    'failed' => CallStatus.failed,
    _ => CallStatus.ringing,
  };
}

/// Mirrors `CALL_END_REASON` in constants.js.
enum CallEndReason {
  callerHangup,
  listenerHangup,
  insufficientBalance,
  disconnect,
  rejected,
  timeout,
  admin,
  unknown;

  static CallEndReason fromJson(String? value) => switch (value) {
    'caller_hangup' => CallEndReason.callerHangup,
    'listener_hangup' => CallEndReason.listenerHangup,
    'insufficient_balance' => CallEndReason.insufficientBalance,
    'disconnect' => CallEndReason.disconnect,
    'rejected' => CallEndReason.rejected,
    'timeout' => CallEndReason.timeout,
    'admin' => CallEndReason.admin,
    _ => CallEndReason.unknown,
  };
}

/// Agora join credentials, issued by the server for one channel.
///
/// [token] is nullable: `agora.js::buildRtcToken` returns null when the
/// backend has no Agora app certificate configured (local development without
/// real Agora credentials). A null token means "join the channel unsecured, if
/// at all" — the Agora service must not treat it as a crash.
class AgoraCredentials {
  const AgoraCredentials({
    required this.channel,
    required this.token,
    required this.uid,
  });

  final String channel;
  final String? token;
  final int uid;

  factory AgoraCredentials.fromJson(Map<String, dynamic> json) {
    return AgoraCredentials(
      channel: json['channel'] as String? ?? '',
      token: json['token'] as String?,
      uid: (json['uid'] as num?)?.toInt() ?? 0,
    );
  }

  /// Whether Agora is actually configured server-side. When false, the app is
  /// running against a dev backend with no Agora app id/certificate — real
  /// media cannot connect, and the UI must say so rather than pretend.
  bool get isConfigured => channel.isNotEmpty;
}

/// Response of `POST /api/calls/initiate`.
class CallInitiation {
  const CallInitiation({
    required this.callId,
    required this.status,
    required this.agora,
    required this.ratePerMinute,
    required this.freeSeconds,
    required this.balance,
  });

  final int callId;
  final CallStatus status;
  final AgoraCredentials agora;
  final int ratePerMinute;
  final int freeSeconds;
  final int balance;

  bool get isFreeTrialEligible => freeSeconds > 0;

  factory CallInitiation.fromJson(Map<String, dynamic> json) {
    return CallInitiation(
      callId: (json['callId'] as num).toInt(),
      status: CallStatus.fromJson(json['status'] as String?),
      agora: AgoraCredentials.fromJson(
        Map<String, dynamic>.from(json['agora'] as Map? ?? const {}),
      ),
      ratePerMinute: (json['ratePerMinute'] as num?)?.toInt() ?? 0,
      freeSeconds: (json['freeSeconds'] as num?)?.toInt() ?? 0,
      balance: (json['balance'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Response of `POST /api/calls/:id/accept`.
class CallAcceptResult {
  const CallAcceptResult({
    required this.callId,
    required this.status,
    required this.startedAt,
    required this.agora,
  });

  final int callId;
  final CallStatus status;
  final DateTime? startedAt;
  final AgoraCredentials agora;

  factory CallAcceptResult.fromJson(Map<String, dynamic> json) {
    return CallAcceptResult(
      callId: (json['callId'] as num).toInt(),
      status: CallStatus.fromJson(json['status'] as String?),
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
      agora: AgoraCredentials.fromJson(
        Map<String, dynamic>.from(json['agora'] as Map? ?? const {}),
      ),
    );
  }
}

/// Response of `POST /api/calls/:id/end`, and the shape of the `call:ended`
/// socket event. `earned` is only present for the listener; `callerBalance` is
/// meaningful to the caller and harmless to ignore for the listener.
class CallSummary {
  const CallSummary({
    required this.callId,
    required this.endReason,
    required this.billedMinutes,
    required this.coinsSpent,
    required this.durationSeconds,
    this.callerBalance,
    this.listenerEarned,
  });

  final int callId;
  final CallEndReason endReason;
  final int billedMinutes;
  final int coinsSpent;
  final int durationSeconds;
  final int? callerBalance;
  final int? listenerEarned;

  factory CallSummary.fromJson(Map<String, dynamic> json) {
    return CallSummary(
      callId: (json['callId'] as num).toInt(),
      endReason: CallEndReason.fromJson(
        (json['endReason'] ?? json['reason']) as String?,
      ),
      billedMinutes: (json['billedMinutes'] as num?)?.toInt() ?? 0,
      coinsSpent: (json['coinsSpent'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      callerBalance: (json['callerBalance'] as num?)?.toInt(),
      listenerEarned:
          (json['listenerEarned'] as num?)?.toInt() ??
          (json['earned'] as num?)?.toInt(),
    );
  }
}

/// `call:incoming` — delivered to the listener only.
class IncomingCallEvent {
  const IncomingCallEvent({
    required this.callId,
    required this.callType,
    required this.callerId,
    required this.callerName,
    required this.agora,
  });

  final int callId;
  final CallType callType;
  final int callerId;
  final String? callerName;
  final AgoraCredentials agora;

  factory IncomingCallEvent.fromJson(Map<String, dynamic> json) {
    final caller = Map<String, dynamic>.from(json['caller'] as Map? ?? const {});
    final callerId = (caller['id'] as num?)?.toInt() ?? 0;
    return IncomingCallEvent(
      callId: (json['callId'] as num).toInt(),
      callType: CallType.fromJson(json['callType'] as String?),
      callerId: callerId,
      callerName: caller['name'] as String?,
      agora: AgoraCredentials(
        channel: json['agoraChannel'] as String? ?? '',
        token: json['agoraToken'] as String?,
        uid: callerId,
      ),
    );
  }
}

/// `call:accepted` — delivered to the caller only.
class CallAcceptedEvent {
  const CallAcceptedEvent({
    required this.callId,
    required this.startedAt,
    required this.freeSeconds,
  });

  final int callId;
  final DateTime? startedAt;
  final int freeSeconds;

  factory CallAcceptedEvent.fromJson(Map<String, dynamic> json) {
    return CallAcceptedEvent(
      callId: (json['callId'] as num).toInt(),
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
      freeSeconds: (json['freeSeconds'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `call:tick`, caller shape: `{ callId, minuteIndex, coinsCharged, balance,
/// minutesRemaining }`. Deliberately a distinct type from [ListenerCallTick] —
/// the two payloads share no fields but `callId`/`minuteIndex`, so forcing them
/// into one model would mean every field is nullable for no benefit.
class CallerCallTick {
  const CallerCallTick({
    required this.callId,
    required this.minuteIndex,
    required this.coinsCharged,
    required this.balance,
    required this.minutesRemaining,
  });

  final int callId;
  final int minuteIndex;
  final int coinsCharged;
  final int balance;
  final int minutesRemaining;

  factory CallerCallTick.fromJson(Map<String, dynamic> json) {
    return CallerCallTick(
      callId: (json['callId'] as num).toInt(),
      minuteIndex: (json['minuteIndex'] as num?)?.toInt() ?? 0,
      coinsCharged: (json['coinsCharged'] as num?)?.toInt() ?? 0,
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      minutesRemaining: (json['minutesRemaining'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `call:tick`, listener shape: `{ callId, minuteIndex, earned }`.
class ListenerCallTick {
  const ListenerCallTick({
    required this.callId,
    required this.minuteIndex,
    required this.earned,
  });

  final int callId;
  final int minuteIndex;
  final int earned;

  factory ListenerCallTick.fromJson(Map<String, dynamic> json) {
    return ListenerCallTick(
      callId: (json['callId'] as num).toInt(),
      minuteIndex: (json['minuteIndex'] as num?)?.toInt() ?? 0,
      earned: (json['earned'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `call:low_balance` — caller only.
class CallLowBalanceEvent {
  const CallLowBalanceEvent({
    required this.callId,
    required this.balance,
    required this.minutesRemaining,
    required this.coinsPerMinute,
  });

  final int callId;
  final int balance;
  final int minutesRemaining;
  final int coinsPerMinute;

  factory CallLowBalanceEvent.fromJson(Map<String, dynamic> json) {
    return CallLowBalanceEvent(
      callId: (json['callId'] as num).toInt(),
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      minutesRemaining: (json['minutesRemaining'] as num?)?.toInt() ?? 0,
      coinsPerMinute: (json['coinsPerMinute'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `call:forced_end`, caller shape: `{ callId, reason, billedMinutes,
/// coinsSpent }`.
class CallerForcedEnd {
  const CallerForcedEnd({
    required this.callId,
    required this.reason,
    required this.billedMinutes,
    required this.coinsSpent,
  });

  final int callId;
  final CallEndReason reason;
  final int billedMinutes;
  final int coinsSpent;

  factory CallerForcedEnd.fromJson(Map<String, dynamic> json) {
    return CallerForcedEnd(
      callId: (json['callId'] as num).toInt(),
      reason: CallEndReason.fromJson(json['reason'] as String?),
      billedMinutes: (json['billedMinutes'] as num?)?.toInt() ?? 0,
      coinsSpent: (json['coinsSpent'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `call:forced_end`, listener shape: adds `earned` on top of the caller shape.
class ListenerForcedEnd {
  const ListenerForcedEnd({
    required this.callId,
    required this.reason,
    required this.billedMinutes,
    required this.coinsSpent,
    required this.earned,
  });

  final int callId;
  final CallEndReason reason;
  final int billedMinutes;
  final int coinsSpent;
  final int earned;

  factory ListenerForcedEnd.fromJson(Map<String, dynamic> json) {
    return ListenerForcedEnd(
      callId: (json['callId'] as num).toInt(),
      reason: CallEndReason.fromJson(json['reason'] as String?),
      billedMinutes: (json['billedMinutes'] as num?)?.toInt() ?? 0,
      coinsSpent: (json['coinsSpent'] as num?)?.toInt() ?? 0,
      earned: (json['earned'] as num?)?.toInt() ?? 0,
    );
  }
}
