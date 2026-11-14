import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../domain/models.dart';

abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureStore implements KeyValueStore {
  final FlutterSecureStorage _storage;
  SecureStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
  Future<AppSettings> loadSettings() async {
    final raw = await read('settings');
    if (raw == null) return AppSettings();
    try {
      return AppSettings.fromJson(object(jsonDecode(raw)));
    } on FormatException {
      throw const ApiFailure('本地设置无法读取，请重新保存设置');
    }
  }
}
