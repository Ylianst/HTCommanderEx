/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License").
See http://www.apache.org/licenses/LICENSE-2.0
*/

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper over the OS-native secret store, mirroring the C#
/// `ISecretStore` seam. Secrets are encrypted at rest by the platform:
/// Keychain (iOS/macOS), Keystore-backed EncryptedSharedPreferences (Android),
/// DPAPI (Windows) and libsecret/Secret Service (Linux).
///
/// The web build has no OS keychain, so [isSupported] is false there and
/// callers fall back to the plaintext data broker (which, on the hosted web
/// build, proxies device-0 settings to the desktop host rather than storing
/// them in the browser).
class SecretStore {
  SecretStore._();
  static final SecretStore instance = SecretStore._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Namespaced so our keys don't collide with anything else in the store.
  static String _key(String name) => 'htc_secret_$name';

  /// Whether an OS-native secret store is available on this platform.
  static bool get isSupported => !kIsWeb;

  /// Reads a secret, or null when absent/unsupported/unreadable.
  Future<String?> read(String name) async {
    if (!isSupported) return null;
    try {
      return await _storage.read(key: _key(name));
    } catch (e) {
      debugPrint('SecretStore.read($name) failed: $e');
      return null;
    }
  }

  /// Writes a secret. A null or empty value deletes the entry.
  Future<void> write(String name, String? value) async {
    if (!isSupported) return;
    try {
      if (value == null || value.isEmpty) {
        await _storage.delete(key: _key(name));
      } else {
        await _storage.write(key: _key(name), value: value);
      }
    } catch (e) {
      debugPrint('SecretStore.write($name) failed: $e');
    }
  }
}
