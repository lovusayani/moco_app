import '../../shared/models/app_config.dart';
import 'api_client.dart';

class ConfigApi {
  const ConfigApi(this._client);

  final ApiClient _client;

  /// `GET /config` — public bootstrap. Called on launch so the client always
  /// renders current rates and packs.
  Future<AppConfig> fetch() {
    return _client.request(
      () => _client.dio.get<dynamic>('/config'),
      (data) => AppConfig.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }
}
