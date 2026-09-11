import '../../shared/models/chat.dart';
import 'api_client.dart';

class ChatApi {
  const ChatApi(this._client);

  final ApiClient _client;

  /// `GET /chat` — conversation list with unread counts.
  Future<List<Conversation>> conversations() {
    return _client.request(
      () => _client.dio.get<dynamic>('/chat'),
      (data) {
        final raw = (data as Map)['conversations'];
        return raw is List
            ? raw
                  .whereType<Map>()
                  .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
                  .toList()
            : const <Conversation>[];
      },
    );
  }

  /// `GET /chat/:userId/messages` — also marks the other side's messages
  /// read as a server-side effect of fetching them.
  Future<MessageHistoryPage> messages(int counterpartyId, {int limit = 50, int? before}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/chat/$counterpartyId/messages',
        queryParameters: {'limit': limit, if (before != null) 'before': before},
      ),
      (data) => MessageHistoryPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `POST /chat/:userId/messages` with `{ body }` — a text message.
  Future<ChatMessage> sendText(int counterpartyId, String body) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/chat/$counterpartyId/messages',
        data: {'body': body},
      ),
      (data) => ChatMessage.fromJson(
        Map<String, dynamic>.from((data as Map)['message'] as Map),
      ),
    );
  }

  /// `POST /chat/:userId/messages` with `{ type: 'image', mediaPath }` — a
  /// photo message, referencing a path this user was already issued by
  /// [requestUploadUrl].
  Future<ChatMessage> sendImage(int counterpartyId, String mediaPath) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/chat/$counterpartyId/messages',
        data: {'type': 'image', 'mediaPath': mediaPath},
      ),
      (data) => ChatMessage.fromJson(
        Map<String, dynamic>.from((data as Map)['message'] as Map),
      ),
    );
  }

  /// `POST /chat/media/upload-url` — authorizes a photo upload. The caller
  /// PUTs the image bytes straight to [ChatUploadAuthorization.uploadUrl];
  /// this API is never handed the image data itself.
  Future<ChatUploadAuthorization> requestUploadUrl(String mimeType) {
    return _client.request(
      () => _client.dio.post<dynamic>(
        '/chat/media/upload-url',
        data: {'mimeType': mimeType},
      ),
      (data) =>
          ChatUploadAuthorization.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `PUT /chat/messages/:messageId/reaction` — idempotent set/change.
  Future<void> setReaction(int messageId, String emoji) {
    return _client.request(
      () => _client.dio.put<dynamic>(
        '/chat/messages/$messageId/reaction',
        data: {'emoji': emoji},
      ),
      (_) {},
    );
  }

  /// `DELETE /chat/messages/:messageId/reaction` — idempotent remove.
  Future<void> removeReaction(int messageId) {
    return _client.request(
      () => _client.dio.delete<dynamic>('/chat/messages/$messageId/reaction'),
      (_) {},
    );
  }
}
