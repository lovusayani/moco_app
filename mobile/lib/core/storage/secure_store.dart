import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Session token storage.
///
/// The token is the user's whole identity to the backend, so it lives in the
/// platform keystore (EncryptedSharedPreferences on Android, Keychain on iOS)
/// and never in SharedPreferences. Non-sensitive local flags — whether
/// onboarding was seen — do go in SharedPreferences, deliberately separated.
abstract class SecureStore {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> clear();
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'moco_auth_token';

  @override
  Future<String?> readToken() async {
    try {
      return await _storage.read(key: _tokenKey);
    } catch (_) {
      // A corrupt keystore entry must not brick the app: treat it as signed out.
      return null;
    }
  }

  @override
  Future<void> writeToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _tokenKey);
}

/// Local, non-sensitive preferences.
class AppPreferences {
  AppPreferences(this._prefs);

  final SharedPreferences _prefs;

  static const _onboardingKey = 'moco_onboarding_complete';

  static Future<AppPreferences> create() async =>
      AppPreferences(await SharedPreferences.getInstance());

  bool get onboardingComplete => _prefs.getBool(_onboardingKey) ?? false;

  Future<void> setOnboardingComplete(bool value) =>
      _prefs.setBool(_onboardingKey, value);
}
