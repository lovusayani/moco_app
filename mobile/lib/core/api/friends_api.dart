import 'api_client.dart';

class FriendsApi {
  const FriendsApi(this._client);

  final ApiClient _client;

  Future<FriendRequestResult> sendRequest(int userId) {
    return _client.request(
      () => _client.dio.post<dynamic>('/friends/request/$userId'),
      (data) => FriendRequestResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<FriendRespondResult> respond(int requestId, {required bool accept}) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/friends/respond/$requestId',
        data: {'accept': accept},
      ),
      (data) => FriendRespondResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<FriendshipStatus> status(int userId) {
    return _client.request(
      () => _client.dio.get<dynamic>('/friends/status/$userId'),
      (data) => FriendshipStatus.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<List<PendingFriendRequest>> pendingRequests() {
    return _client.request(
      () => _client.dio.get<dynamic>('/friends/requests'),
      (data) {
        final raw = (data as Map)['requests'];
        return raw is List
            ? raw
                  .whereType<Map>()
                  .map((e) => PendingFriendRequest.fromJson(Map<String, dynamic>.from(e)))
                  .toList()
            : const <PendingFriendRequest>[];
      },
    );
  }
}

class FriendRequestResult {
  const FriendRequestResult({required this.requestId, required this.status});

  final int requestId;
  final String status;

  factory FriendRequestResult.fromJson(Map<String, dynamic> json) {
    return FriendRequestResult(
      requestId: (json['requestId'] as num).toInt(),
      status: json['status'] as String,
    );
  }
}

class FriendRespondResult {
  const FriendRespondResult({required this.requestId, required this.status});

  final int requestId;
  final String status;

  factory FriendRespondResult.fromJson(Map<String, dynamic> json) {
    return FriendRespondResult(
      requestId: (json['requestId'] as num).toInt(),
      status: json['status'] as String,
    );
  }
}

class FriendshipStatus {
  const FriendshipStatus({
    required this.status,
    this.requestId,
    this.requesterId,
    this.targetId,
  });

  final String status;
  final int? requestId;
  final int? requesterId;
  final int? targetId;

  factory FriendshipStatus.fromJson(Map<String, dynamic> json) {
    return FriendshipStatus(
      status: json['status'] as String? ?? 'none',
      requestId: (json['requestId'] as num?)?.toInt(),
      requesterId: (json['requesterId'] as num?)?.toInt(),
      targetId: (json['targetId'] as num?)?.toInt(),
    );
  }
}

class PendingFriendRequest {
  const PendingFriendRequest({
    required this.requestId,
    required this.requesterName,
    this.requesterAvatarUrl,
    required this.requesterId,
    required this.createdAt,
  });

  final int requestId;
  final String requesterName;
  final String? requesterAvatarUrl;
  final int requesterId;
  final String createdAt;

  factory PendingFriendRequest.fromJson(Map<String, dynamic> json) {
    final requester = json['requester'] as Map<String, dynamic>? ?? {};
    return PendingFriendRequest(
      requestId: (json['requestId'] as num).toInt(),
      requesterName: requester['name'] as String? ?? 'Someone',
      requesterAvatarUrl: requester['avatarUrl'] as String?,
      requesterId: (requester['id'] as num).toInt(),
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}
