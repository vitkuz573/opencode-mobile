import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/api.dart';
import '../data/console.dart';

/// Persists server profiles in the Android Keystore-backed secure storage.
///
/// Passwords and pairing cookies are secrets, so they never touch
/// `SharedPreferences` or plain files.
class ProfileStore {
  ProfileStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          // AndroidOptions defaults to AES-GCM with RSA-wrapped keys in the
          // Android KeyStore; there is no opt-in flag to set in v11.
          const FlutterSecureStorage();

  static const _key = 'opencode.profiles.v1';
  static const _hostsKey = 'opencode.remoteHosts.v1';
  static const _consoleKey = 'opencode.console.v1';
  static const _appLockKey = 'opencode.appLock.v1';
  static const _localPortKey = 'opencode.localPort.v1';

  final FlutterSecureStorage _storage;

  Future<List<ServerProfile>> loadAll() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => ServerProfile.fromJson(e.cast<String, Object?>()))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAll(List<ServerProfile> profiles) {
    return _storage.write(
      key: _key,
      value: jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  /// Addresses the server has advertised in /api/info and that a phone could
  /// actually reach, newest first.
  ///
  /// Pairing codes are not bound to a host, so this is what lets a loopback
  /// link be redeemed over a tunnel.
  Future<List<String>> loadRemoteHosts() async {
    final raw = await _storage.read(key: _hostsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }


  // --- opencode.ai account ---------------------------------------------------

  /// The signed-in Console session, if any. Refresh tokens are single use, so
  /// the whole session is rewritten on every renewal.
  Future<ConsoleSession?> loadConsoleSession() async {
    final raw = await _storage.read(key: _consoleKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ConsoleSession.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Future<void> saveConsoleSession(ConsoleSession session) {
    return _storage.write(key: _consoleKey, value: jsonEncode(session.toJson()));
  }

  Future<void> clearConsoleSession() => _storage.delete(key: _consoleKey);
  Future<void> rememberRemoteHosts(Iterable<String> candidates) async {
    final existing = await loadRemoteHosts();
    final merged = <String>[
      ...candidates.where((h) => h.isNotEmpty),
      ...existing.where((h) => !candidates.contains(h)),
    ];
    final trimmed = merged.take(8).toList(growable: false);
    await _storage.write(key: _hostsKey, value: jsonEncode(trimmed));
  }

  // --- app lock ------------------------------------------------------------

  /// Whether the app asks for the fingerprint (or the device PIN as a
  /// fallback) before showing anything. A plain flag next to the secrets it
  /// guards: anyone past the lock already owns the secrets, and anyone short
  /// of it never reaches the code that reads them.
  Future<bool> loadAppLockEnabled() async {
    return await _storage.read(key: _appLockKey) == '1';
  }

  Future<void> saveAppLockEnabled(bool enabled) {
    return _storage.write(key: _appLockKey, value: enabled ? '1' : '0');
  }

  // --- phone server ----------------------------------------------------------

  /// The port the phone's server used last. Restarts prefer it when it is
  /// free, so the address — and every saved profile pointing at it — survives
  /// a restart instead of going stale on a new random port.
  Future<int?> loadLocalPort() async {
    final port = int.tryParse(await _storage.read(key: _localPortKey) ?? '');
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  Future<void> saveLocalPort(int port) {
    return _storage.write(key: _localPortKey, value: '$port');
  }
}