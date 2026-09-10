import '../../shared/models/call.dart';
import 'api_client.dart';

/// `/api/calls/*` — the server owns every decision here (pre-flight balance,
/// billing, forced end). This class only shapes requests/responses; it never
/// computes a rate, a balance or a minute count itself.
class CallsApi {
  const CallsApi(this._client);

  final ApiClient _client;

  /// `POST /calls/initiate`. Runs the pre-flight balance check server-side and
  /// atomically claims the listener — a 409 means someone else got there first,
  /// a 402 means the balance cannot fund even one minute.
  Future<CallInitiation> initiate({
    required int listenerId,
    required CallType type,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/calls/initiate',
        data: {'listenerId': listenerId, 'type': type.toJson()},
      ),
      (data) => CallInitiation.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /calls/:id/accept` — listener only. Starts the meter server-side.
  Future<CallAcceptResult> accept(int callId) {
    return _client.request(
      () => _client.dio.post<dynamic>('/calls/$callId/accept'),
      (data) =>
          CallAcceptResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /calls/:id/end` — either participant. Idempotent server-side: a
  /// second call returns the same settled summary rather than erroring, so a
  /// race between the user tapping End and a forced-end event is always safe.
  Future<CallSummary> end(int callId, {CallEndReason? reason}) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/calls/$callId/end',
        data: reason == null ? const {} : {'reason': _reasonToJson(reason)},
      ),
      (data) => CallSummary.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  static String? _reasonToJson(CallEndReason reason) => switch (reason) {
    CallEndReason.rejected => 'rejected',
    CallEndReason.disconnect => 'disconnect',
    _ => null, // Only these two are accepted by the endpoint; anything else
    // is derived server-side from the call's current status/actor.
  };
}
