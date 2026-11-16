// Port of javascript/oursprivacy-storage.js.
//
// The SDK persists through [OursPrivacyStorage]. The default backend is
// `shared_preferences` (NSUserDefaults on iOS, SharedPreferences on Android).
// Hosts can pass their own implementation to `OursPrivacy.init(storage:)`.
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:shared_preferences/shared_preferences.dart';

import 'errors.dart';
import 'logger.dart';

/// Key-value string storage used by the SDK. Mirrors React Native's
/// AsyncStorage contract: `getItem` returns null for a missing key.
/// Implementations should throw on failure; the SDK decides which failures
/// are fatal. A failure that reaches a caller of `OursPrivacy` is reported as
/// an [OursPrivacyException] whose `cause` is the error thrown here.
abstract class OursPrivacyStorage {
  Future<String?> getItem(String key);
  Future<void> setItem(String key, String value);
  Future<void> removeItem(String key);
}

/// Volatile storage. Used for tests and as a last-resort fallback when the
/// shared_preferences plugin is unavailable (for example in a pure Dart VM).
class InMemoryStorage implements OursPrivacyStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> getItem(String key) async => _store[key];

  @override
  Future<void> setItem(String key, String value) async => _store[key] = value;

  @override
  Future<void> removeItem(String key) async => _store.remove(key);

  /// Snapshot of the stored values, for tests.
  Map<String, String> get values => Map.unmodifiable(_store);
}

/// Default backend over the legacy `SharedPreferences` API (the only API
/// available at the Flutter 3.13 floor). `setString` reports failure by
/// returning false; this adapter turns that into an [OursPrivacyException] so
/// strict callers can roll back.
///
/// A failed load is not cached: the next operation calls the loader again,
/// so a transient plugin failure affects only the calls made while it lasts
/// (like React Native, where each AsyncStorage call stands alone).
class SharedPreferencesStorage implements OursPrivacyStorage {
  SharedPreferencesStorage([Future<SharedPreferences> Function()? load])
      : _load = load ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _load;
  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _prefs => _preferences ??= _loadOnce();

  Future<SharedPreferences> _loadOnce() async {
    try {
      // Future.sync keeps a synchronous throw asynchronous, so the failed
      // future is already stored when it is cleared here.
      return await Future<SharedPreferences>.sync(_load);
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }

  @override
  Future<String?> getItem(String key) async => (await _prefs).getString(key);

  @override
  Future<void> setItem(String key, String value) async {
    final ok = await (await _prefs).setString(key, value);
    if (!ok) {
      throw OursPrivacyException('OursPrivacy storage write failed for $key');
    }
  }

  @override
  Future<void> removeItem(String key) async {
    final ok = await (await _prefs).remove(key);
    if (!ok) {
      throw OursPrivacyException('OursPrivacy storage remove failed for $key');
    }
  }
}

/// Wraps a backend with RN's two access modes: the plain methods swallow and
/// log failures; the `Strict` methods propagate them.
class StorageAdapter {
  StorageAdapter(OursPrivacyStorage? storage)
      : storage = storage ?? _FallbackStorage();

  final OursPrivacyStorage storage;

  Future<String?> getItem(String key) async {
    try {
      return await storage.getItem(key);
    } catch (_) {
      OursPrivacyLogger.error(null, 'error getting item from storage');
      return null;
    }
  }

  Future<void> setItem(String key, String value) async {
    try {
      await storage.setItem(key, value);
    } catch (_) {
      OursPrivacyLogger.error(null, 'error setting item in storage');
    }
  }

  Future<void> removeItem(String key) async {
    try {
      await storage.removeItem(key);
    } catch (_) {
      OursPrivacyLogger.error(null, 'error removing item from storage');
    }
  }

  /// Reads [key]; a backend failure propagates as an
  /// [OursPrivacyException] whose `cause` is the backend's error.
  Future<String?> getItemStrict(String key) => _strict(
        () => storage.getItem(key),
        'OursPrivacy storage read failed for $key',
      );

  /// Writes [key]; a backend failure propagates as an
  /// [OursPrivacyException] whose `cause` is the backend's error.
  Future<void> setItemStrict(String key, String value) => _strict(
        () => storage.setItem(key, value),
        'OursPrivacy storage write failed for $key',
      );

  static Future<T> _strict<T>(
    Future<T> Function() operation,
    String message,
  ) async {
    try {
      // Future.sync turns a synchronous throw from the backend into a failed
      // future, so it is wrapped like an asynchronous one.
      return await Future<T>.sync(operation);
    } on OursPrivacyException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        OursPrivacyException(message, cause: error),
        stackTrace,
      );
    }
  }
}

/// shared_preferences, falling back to [InMemoryStorage] only when the plugin
/// is missing (MissingPluginException), like RN's AsyncStorage fallback.
class _FallbackStorage implements OursPrivacyStorage {
  final SharedPreferencesStorage _primary = SharedPreferencesStorage();
  OursPrivacyStorage? _fallback;

  Future<T> _run<T>(Future<T> Function(OursPrivacyStorage s) op) async {
    final fallback = _fallback;
    if (fallback != null) return op(fallback);
    try {
      return await op(_primary);
    } on MissingPluginException {
      OursPrivacyLogger.error(
          null,
          'shared_preferences is unavailable; falling back to in-memory '
          'storage. Visitor ID, consent, and queued events will not persist.');
      return op(_fallback ??= InMemoryStorage());
    }
  }

  @override
  Future<String?> getItem(String key) => _run((s) => s.getItem(key));

  @override
  Future<void> setItem(String key, String value) =>
      _run((s) => s.setItem(key, value));

  @override
  Future<void> removeItem(String key) => _run((s) => s.removeItem(key));
}
