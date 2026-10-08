import '../../shared/models/live.dart';
import 'api_client.dart';

/// Moco Live. The app only ever talks to Moco's backend — never to the
/// provider: listings, curation and geobans are all applied server-side.
class LiveApi {
  const LiveApi(this._client);

  final ApiClient _client;

  /// `GET /live/config` — whether Live is on, the 18+ gate, the admin's
  /// layout/card/sort/tap settings and the non-secret player settings.
  Future<LiveConfig> config() {
    return _client.request(
      () => _client.dio.get<dynamic>('/live/config'),
      (data) => LiveConfig.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// `GET /live/models` — one page, in the backend's order.
  Future<LiveModelsPage> models({required int limit, int offset = 0}) {
    return _client.request(
      () => _client.dio.get<dynamic>(
        '/live/models',
        queryParameters: {'limit': limit, 'offset': offset},
      ),
      (data) => LiveModelsPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}
