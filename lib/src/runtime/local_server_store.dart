import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What the phone-hosted server needs to be talked to again after a restart.
///
/// The password is a secret, so it lives in the Android Keystore-backed storage
/// alongside the other credentials rather than in a plain file.
class LocalServerCredentials {
  const LocalServerCredentials({
    required this.port,
    required this.password,
  });

  final int port;
  final String password;

  Map<String, Object?> toJson() => {'port': port, 'password': password};

  factory LocalServerCredentials.fromJson(Map<String, Object?> json) {
    final port = json['port'];
    final password = json['password'];
    if (port is! int || password is! String || password.isEmpty) {
      throw const FormatException('not local server credentials');
    }
    return LocalServerCredentials(port: port, password: password);
  }
}

class LocalServerStore {
  LocalServerStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'opencode.localServer.v1';

  final FlutterSecureStorage _storage;

  Future<LocalServerCredentials?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return LocalServerCredentials.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LocalServerCredentials credentials) {
    return _storage.write(key: _key, value: jsonEncode(credentials.toJson()));
  }

  Future<void> clear() => _storage.delete(key: _key);
}