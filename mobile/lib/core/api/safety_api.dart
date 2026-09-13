import 'api_client.dart';

/// Report and block, against the existing `/api/safety` endpoints.
///
/// The backend has carried these since Phase 1; this is the first client that
/// calls them. Nothing about the safety model changes here — no second block
/// list, no client-side filtering. Blocking is a server action, and every
/// discovery, chat and feed query already excludes blocked users in both
/// directions, so the effect of a successful call is simply that the server
/// stops returning that user.
class SafetyApi {
  const SafetyApi(this._client);

  final ApiClient _client;

  /// Reason codes the backend accepts. Sending anything else is a 400.
  static const reportReasons = <String, String>{
    'harassment': 'Harassment or bullying',
    'nudity': 'Nudity or sexual content',
    'abusive_language': 'Abusive language',
    'spam': 'Spam or scam',
    'underage': 'User appears to be underage',
    'impersonation': 'Impersonation',
    'other': 'Something else',
  };

  /// `POST /safety/report`. [callId] links a report to the call it happened
  /// on, when there was one — the backend accepts it optionally.
  Future<void> report({
    required int userId,
    required String reason,
    String? details,
    int? callId,
  }) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/safety/report',
        data: {
          'userId': userId,
          'reason': reason,
          if (details != null && details.trim().isNotEmpty)
            'details': details.trim(),
          if (callId != null) 'callId': callId,
        },
      ),
      (_) {},
    );
  }

  /// `POST /safety/block` — also ends any live call between the two.
  Future<void> block(int userId) {
    return _client.request(
      () => _client.dio.post<dynamic>('/safety/block', data: {'userId': userId}),
      (_) {},
    );
  }

  /// `DELETE /safety/block/:userId`.
  Future<void> unblock(int userId) {
    return _client.request(
      () => _client.dio.delete<dynamic>('/safety/block/$userId'),
      (_) {},
    );
  }
}
