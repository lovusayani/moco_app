// prefer_initializing_formals suggests `required this._callsApi`, which Dart
// rejects: a named parameter may not be a private name (see auth_controller.dart).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/calls_api.dart';
import '../errors/api_exception.dart';
import '../providers.dart';
import '../realtime/socket_service.dart';
import '../utils/ws_events.dart';
import '../../shared/models/call.dart';
import '../../shared/models/listener.dart';
import 'agora_call_service.dart';
import 'call_session.dart';

/// Owns the whole call lifecycle: talks to [CallsApi], listens to the
/// call-related Socket.IO events, drives [AgoraCallService], and emits the
/// `heartbeat` the backend's disconnect sweeper expects.
///
/// One instance lives for the app's lifetime (see [callControllerProvider]),
/// subscribed to the socket regardless of which screen is on top — an
/// incoming call must be caught even while the caller is browsing Discovery.
/// Billing itself never happens here: every coin figure displayed is a copy of
/// a number the server already sent.
class CallController extends StateNotifier<CallSession> {
  CallController({
    required CallsApi callsApi,
    required SocketService socket,
    required AgoraCallService agora,
  }) : _callsApi = callsApi,
       _socket = socket,
       _agora = agora,
       super(const CallSession()) {
    _socketOffs
      ..add(_socket.on(WsEvents.incomingCall, _onIncoming))
      ..add(_socket.on(WsEvents.callAccepted, _onAccepted))
      ..add(_socket.on(WsEvents.tick, _onTick))
      ..add(_socket.on(WsEvents.lowBalance, _onLowBalance))
      ..add(_socket.on(WsEvents.forcedEnd, _onForcedEnd))
      ..add(_socket.on(WsEvents.callEnded, _onEnded));
    _agora.connectionStatus.addListener(_onAgoraStatus);
    _agora.remoteJoined.addListener(_onRemoteJoined);
    _socket.status.addListener(_onSocketStatus);
  }

  final CallsApi _callsApi;
  final SocketService _socket;
  final AgoraCallService _agora;

  final List<VoidCallback> _socketOffs = [];
  Timer? _heartbeatTimer;

  /// True once this call has a settled outcome (a summary from either the
  /// REST end response or the `call:ended`/`call:forced_end` socket events).
  /// Whichever arrives first wins; every other path becomes a no-op, which is
  /// what makes ending a call safe under every race in Phase 2 §18/§29.
  bool _finalized = false;

  // ---- User-initiated actions --------------------------------------------

  /// Caller taps an Audio/Video CTA. Guards against a double tap and against
  /// starting a second call while one is already in progress.
  Future<void> initiateCall({
    required ListenerDetail listener,
    required CallType type,
  }) async {
    if (state.phase != CallPhase.idle || state.isBusy) return;

    state = CallSession(
      phase: CallPhase.initiating,
      role: CallRole.caller,
      callType: type,
      counterpartyId: listener.id,
      counterpartyName: listener.name,
      counterpartyAvatarUrl: listener.avatarUrl,
      isBusy: true,
    );
    _finalized = false;

    try {
      final result = await _callsApi.initiate(
        listenerId: listener.id,
        type: type,
      );
      state = state.copyWith(
        phase: CallPhase.ringing,
        callId: result.callId,
        agora: result.agora,
        ratePerMinute: result.ratePerMinute,
        freeSecondsGranted: result.freeSeconds,
        balance: result.balance,
        isBusy: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(
        phase: e.kind == ApiErrorKind.insufficientBalance
            ? CallPhase.insufficientBalance
            : CallPhase.failed,
        error: e,
        isBusy: false,
      );
    }
  }

  /// Caller cancels before the listener has answered.
  Future<void> cancelOutgoing() async {
    if (state.phase != CallPhase.ringing) return;
    await _settleLocally(terminalPhase: CallPhase.cancelled);
  }

  /// Listener accepts an incoming call.
  Future<void> acceptCall() async {
    if (state.phase != CallPhase.incoming || state.isBusy) return;
    final callId = state.callId;
    if (callId == null) return;

    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final result = await _callsApi.accept(callId);
      if (_finalized) return; // caller cancelled/forced-end won the race

      // The server is active NOW — start the heartbeat regardless of how long
      // Agora takes to actually join the channel.
      state = state.copyWith(
        phase: CallPhase.connecting,
        agora: result.agora,
        startedAt: result.startedAt ?? DateTime.now(),
        isBusy: false,
      );
      _startHeartbeat(callId);
      unawaited(_joinAgoraAndAdvance());
    } on ApiException catch (e) {
      if (_finalized) return;
      state = state.copyWith(phase: CallPhase.failed, error: e, isBusy: false);
    }
  }

  /// Listener declines an incoming call.
  Future<void> declineCall() async {
    if (state.phase != CallPhase.incoming || state.isBusy) return;
    await _settleLocally(
      terminalPhase: CallPhase.rejected,
      reason: CallEndReason.rejected,
    );
  }

  /// Either party ends an active (or connecting) call.
  Future<void> endCall() async {
    if (!state.isInCall) return;
    await _settleLocally(terminalPhase: CallPhase.ended);
  }

  /// Returns to [CallPhase.idle] once the summary/incoming screen is
  /// dismissed, so the controller is ready for the next call.
  void reset() {
    if (state.phase == CallPhase.idle) return;
    _finalized = false;
    state = const CallSession();
  }

  /// Re-checks the call's authoritative state against the server.
  ///
  /// The socket is the live source of truth during normal operation, but it
  /// does not replay missed events — if the app was backgrounded or the
  /// socket briefly dropped exactly while a forced-end or call:ended event
  /// was delivered, that event is gone for good. Called on app resume and on
  /// socket reconnect while a call is in progress, so a call that already
  /// ended server-side cannot leave the UI stuck showing it as live.
  Future<void> reconcile() async {
    if (_finalized) return;
    final callId = state.callId;
    if (callId == null || !state.isInCall) return;

    CallLiveState live;
    try {
      live = await _callsApi.get(callId);
    } on ApiException {
      // A failed reconciliation check is not itself a reason to end the
      // call — the next heartbeat/tick or the next reconcile() will try
      // again. Only the server actually ending the call does that.
      return;
    }
    if (_finalized || live.callId != state.callId) return;

    if (live.status == CallStatus.ended || live.status == CallStatus.failed) {
      _finalized = true;
      _stopHeartbeat();
      unawaited(_agora.leave());
      final reason = live.endReason ?? CallEndReason.unknown;
      state = state.copyWith(
        phase: reason == CallEndReason.insufficientBalance
            ? CallPhase.insufficientBalance
            : CallPhase.ended,
        summary: CallSummary(
          callId: live.callId,
          endReason: reason,
          billedMinutes: live.billedMinutes,
          coinsSpent: live.coinsSpent,
          durationSeconds: live.durationSeconds,
        ),
      );
    }
    // Still active/ringing server-side: nothing to reconcile — the socket
    // resumes delivering ticks normally once reconnected.
  }

  // ---- Shared end/settle path ---------------------------------------------

  Future<void> _settleLocally({
    required CallPhase terminalPhase,
    CallEndReason? reason,
  }) async {
    if (state.isBusy || _finalized) return;
    final callId = state.callId;
    if (callId == null) return;

    state = state.copyWith(phase: CallPhase.ending, isBusy: true);
    _stopHeartbeat();
    await _agora.leave();

    try {
      final summary = await _callsApi.end(callId, reason: reason);
      if (_finalized) return; // a socket event already settled it
      _finalized = true;
      state = state.copyWith(phase: terminalPhase, summary: summary, isBusy: false);
    } on ApiException catch (e) {
      if (_finalized) return;
      // The call is torn down locally either way — a network failure here
      // must not leave the UI stuck on a call that Agora already left.
      _finalized = true;
      state = state.copyWith(phase: terminalPhase, error: e, isBusy: false);
    }
  }

  // ---- Agora ----------------------------------------------------------------

  Future<void> _joinAgoraAndAdvance() async {
    final credentials = state.agora;
    final type = state.callType;
    if (credentials == null || type == null) return;

    await _agora.join(credentials: credentials, type: type);
    if (_finalized) {
      await _agora.leave();
      return;
    }

    // No Agora credentials configured (local dev) or already connected by the
    // time join() returned: nothing more to wait for, so advance now rather
    // than sitting in "connecting" forever. A genuinely async connect is
    // caught by [_onAgoraStatus] instead.
    if (!credentials.isConfigured ||
        _agora.connectionStatus.value == RtcConnectionStatus.connected) {
      if (state.phase == CallPhase.connecting) {
        state = state.copyWith(phase: CallPhase.active);
      }
    }
  }

  void _onAgoraStatus() {
    if (_finalized) return;
    if (state.phase == CallPhase.connecting &&
        _agora.connectionStatus.value == RtcConnectionStatus.connected) {
      state = state.copyWith(phase: CallPhase.active);
    }
  }

  void _onRemoteJoined() {
    if (_finalized) return;
    state = state.copyWith(remoteJoined: _agora.remoteJoined.value);
  }

  /// A socket blip mid-call is not a server-authoritative end — only the
  /// server may end a call. This purely reflects connectivity for the UI.
  void _onSocketStatus() {
    if (_finalized) return;
    final connectivity = _socket.status.value;
    if (state.phase == CallPhase.active &&
        connectivity != SocketStatus.connected) {
      state = state.copyWith(phase: CallPhase.reconnecting);
    } else if (state.phase == CallPhase.reconnecting &&
        connectivity == SocketStatus.connected) {
      state = state.copyWith(phase: CallPhase.active);
      // The socket may have missed an end event while it was down — confirm
      // the call is genuinely still active rather than assume it.
      unawaited(reconcile());
    }
  }

  // ---- Heartbeat --------------------------------------------------------

  /// Emitted while the server considers the call active, so the backend's
  /// disconnect sweeper (staleAfterSeconds = 3 * TICK_INTERVAL_SECONDS = 180s)
  /// never mistakes a live call for a dropped one. 20s keeps a wide margin
  /// under both that and the 90s presence TTL the same event refreshes.
  static const _heartbeatInterval = Duration(seconds: 20);

  void _startHeartbeat(int callId) {
    _heartbeatTimer?.cancel();
    _socket.emit('heartbeat', {'callId': callId});
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _socket.emit('heartbeat', {'callId': callId});
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Exposed for tests — asserting on a private [Timer] otherwise means either
  /// waiting out the real 20s interval or reaching into private state.
  @visibleForTesting
  bool get debugHeartbeatActive => _heartbeatTimer?.isActive ?? false;

  // ---- Socket event handlers ----------------------------------------------

  void _onIncoming(dynamic data) {
    if (data is! Map) return;
    final event = IncomingCallEvent.fromJson(Map<String, dynamic>.from(data));

    // Already tracking a call (including this same event redelivered after a
    // reconnect): never clobber it.
    if (state.phase != CallPhase.idle) return;

    _finalized = false;
    state = CallSession(
      phase: CallPhase.incoming,
      role: CallRole.listener,
      callId: event.callId,
      callType: event.callType,
      counterpartyId: event.callerId,
      counterpartyName: event.callerName,
      agora: event.agora,
    );
  }

  void _onAccepted(dynamic data) {
    if (_finalized || data is! Map) return;
    if (state.role != CallRole.caller || state.phase != CallPhase.ringing) return;

    final event = CallAcceptedEvent.fromJson(Map<String, dynamic>.from(data));
    if (event.callId != state.callId) return;

    state = state.copyWith(
      phase: CallPhase.connecting,
      startedAt: event.startedAt ?? DateTime.now(),
      freeSecondsGranted: event.freeSeconds,
    );
    _startHeartbeat(event.callId);
    unawaited(_joinAgoraAndAdvance());
  }

  void _onTick(dynamic data) {
    if (_finalized || data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    final callId = (json['callId'] as num?)?.toInt();
    if (callId == null || callId != state.callId) return;

    if (state.role == CallRole.caller) {
      final tick = CallerCallTick.fromJson(json);
      state = state.copyWith(
        balance: tick.balance,
        minutesRemaining: tick.minutesRemaining,
        lowBalance: false,
      );
    } else if (state.role == CallRole.listener) {
      final tick = ListenerCallTick.fromJson(json);
      state = state.copyWith(earnedThisCall: state.earnedThisCall + tick.earned);
    }
  }

  void _onLowBalance(dynamic data) {
    if (_finalized || data is! Map) return;
    if (state.role != CallRole.caller) return;
    final event = CallLowBalanceEvent.fromJson(Map<String, dynamic>.from(data));
    if (event.callId != state.callId) return;

    state = state.copyWith(
      balance: event.balance,
      minutesRemaining: event.minutesRemaining,
      lowBalance: true,
    );
  }

  void _onForcedEnd(dynamic data) {
    if (_finalized || data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    final callId = (json['callId'] as num?)?.toInt();
    if (callId == null || callId != state.callId) return;

    _finalized = true;
    _stopHeartbeat();
    unawaited(_agora.leave());

    final reason = CallEndReason.fromJson(json['reason'] as String?);
    final summary = CallSummary(
      callId: callId,
      endReason: reason,
      billedMinutes: (json['billedMinutes'] as num?)?.toInt() ?? 0,
      coinsSpent: (json['coinsSpent'] as num?)?.toInt() ?? 0,
      durationSeconds: 0,
      listenerEarned: (json['earned'] as num?)?.toInt(),
    );

    state = state.copyWith(
      phase: reason == CallEndReason.insufficientBalance
          ? CallPhase.insufficientBalance
          : CallPhase.ended,
      summary: summary,
    );
  }

  void _onEnded(dynamic data) {
    if (_finalized || data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    final callId = (json['callId'] as num?)?.toInt();
    if (callId == null || callId != state.callId) return;

    _finalized = true;
    _stopHeartbeat();
    unawaited(_agora.leave());

    final summary = CallSummary.fromJson(json);
    state = state.copyWith(
      phase: CallPhase.ended,
      summary: summary,
      balance: summary.callerBalance ?? state.balance,
    );
  }

  @override
  void dispose() {
    for (final off in _socketOffs) {
      off();
    }
    _stopHeartbeat();
    // The Agora service is owned by agoraCallServiceProvider, not this
    // controller — it disposes its own service via ref.onDispose. Disposing
    // it again here would double-dispose its ValueNotifiers.
    _agora.connectionStatus.removeListener(_onAgoraStatus);
    _agora.remoteJoined.removeListener(_onRemoteJoined);
    _socket.status.removeListener(_onSocketStatus);
    super.dispose();
  }
}

final agoraCallServiceProvider = Provider<AgoraCallService>((ref) {
  final service = AgoraCallService();
  ref.onDispose(() => service.dispose());
  return service;
});

final callsApiProvider = Provider<CallsApi>(
  (ref) => CallsApi(ref.watch(apiClientProvider)),
);

/// One controller for the app's lifetime — see the class doc for why.
final callControllerProvider =
    StateNotifierProvider<CallController, CallSession>((ref) {
      return CallController(
        callsApi: ref.watch(callsApiProvider),
        socket: ref.watch(socketServiceProvider),
        agora: ref.watch(agoraCallServiceProvider),
      );
    });
