import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureKeyValueStore {
  Future<void> saveString(String key, String value);
  Future<String?> readString(String key);
  Future<void> deleteString(String key);
}

class SecureKeys implements SecureKeyValueStore {
  SecureKeys._();

  static final SecureKeys instance = SecureKeys._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  Future<void> saveJwt(String token) async {
    await _storage.write(key: 'flexiyo.jwt', value: token);
  }

  Future<String?> getJwt() async {
    return _storage.read(key: 'flexiyo.jwt');
  }

  Future<void> clearJwt() async {
    await _storage.delete(key: 'flexiyo.jwt');
  }

  @override
  Future<void> saveString(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<String?> readString(String key) async {
    return _storage.read(key: key);
  }

  @override
  Future<void> deleteString(String key) async {
    await _storage.delete(key: key);
  }
}

final secureKeysProvider = Provider<SecureKeys>((ref) => SecureKeys.instance);
