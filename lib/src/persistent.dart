// Port of javascript/oursprivacy-persistent.js (React Native SDK).
//
// Visitor identity, the mobile install marker, the tracking (opt-out)
// decision and the event queue rows, all persisted through
// [OursPrivacyStorage]. React Native keeps one process-wide instance; here
// there is one shared instance per storage backend (and per-token state
// inside it), so two SDK instances on the same storage and token share the
// same in-memory state and never overwrite each other's keys.
//
// Not ported: super properties, time events and the app-has-opened-before
// flag. Nothing in the React Native SDK writes them and Flutter has no
// earlier release that could have.
import 'dart:async';
import 'dart:convert';

import 'constants.dart';
import 'errors.dart';
import 'logger.dart';
import 'storage.dart';
import 'utils.dart';

/// Install marker values stored under [mobileInstallKey].
const String mobileInstallFresh = 'fresh';
const String mobileInstallLegacy = 'legacy';

OursPrivacyStorage? _defaultStorage;
final Map<OursPrivacyStorage, OursPrivacyPersistent> _instances =
    Map.identity();

/// Resolves the storage backend the SDK uses for [storage]: the host's own
/// backend, or one process-wide default (shared_preferences with an
/// in-memory fallback). Use it wherever storage identity matters, for example
/// to decide whether two SDK instances share a mobile session.
OursPrivacyStorage resolveOursPrivacyStorage(OursPrivacyStorage? storage) =>
    storage ?? (_defaultStorage ??= StorageAdapter(null).storage);

class OursPrivacyPersistent {
  OursPrivacyPersistent._(this.storage)
      : storageAdapter = StorageAdapter(storage);

  /// The shared instance for [storage] (null means the default backend).
  static OursPrivacyPersistent of(OursPrivacyStorage? storage) {
    final resolved = resolveOursPrivacyStorage(storage);
    return _instances.putIfAbsent(
        resolved, () => OursPrivacyPersistent._(resolved));
  }

  /// Test hook: forget every shared instance and the default backend.
  static void resetForTesting() {
    _instances.clear();
    _defaultStorage = null;
  }

  /// The backend this instance reads and writes.
  final OursPrivacyStorage storage;
  final StorageAdapter storageAdapter;

  final Map<String, String?> _visitorId = {};
  final Set<String> _identityLoaded = {};
  final Map<String, bool> _existingInstall = {};
  final Map<String, bool> _optedOut = {};
  final Map<String, bool> _optOutLoaded = {};
  final Map<String, bool> _storedOptOutDecision = {};
  final Map<String, bool> _storedOptOutDefault = {};
  final Map<String, int> _optOutRevision = {};

  /// Loads identity and the tracking decision in parallel. Fails (and leaves
  /// tracking closed) when either strict read fails or a stored value is
  /// malformed.
  Future<void> initializationComplete(String token) async {
    await Future.wait<void>([
      loadIdentity(token),
      loadOptOut(token),
    ], eagerError: true);
  }

  Future<void> loadVisitorId(String token) async {
    final visitorId = await storageAdapter.getItemStrict(visitorIdKey(token));
    var installation =
        await storageAdapter.getItemStrict(mobileInstallKey(token));
    if (installation != null &&
        installation != mobileInstallFresh &&
        installation != mobileInstallLegacy) {
      throw const OursPrivacyException('Invalid stored mobile installation');
    }
    if (installation == null) {
      installation = visitorId != null && visitorId.isNotEmpty
          ? mobileInstallLegacy
          : mobileInstallFresh;
      await storageAdapter.setItemStrict(mobileInstallKey(token), installation);
    }
    _existingInstall[token] = installation == mobileInstallLegacy;
    _identityLoaded.add(token);
    _visitorId[token] = visitorId;
    if (visitorId == null || visitorId.isEmpty) {
      final created = uuidv4();
      _visitorId[token] = created;
      await storageAdapter.setItemStrict(visitorIdKey(token), created);
    }
    OursPrivacyLogger.log(token, 'visitorId: ${_visitorId[token]}');
  }

  Future<void> loadIdentity(String token) => loadVisitorId(token);

  Future<void> persistIdentity(String token) => persistVisitorId(token);

  /// True when this install had a visitor ID before the mobile install marker
  /// existed (an upgrade), so no `$mobile_first_open` is owed.
  bool hasExistingInstall(String token) => _existingInstall[token] == true;

  /// The current visitor ID, or null before identity has loaded.
  String? getVisitorId(String token) =>
      _identityLoaded.contains(token) ? _visitorId[token] : null;

  /// Updates the in-memory visitor ID; call [persistVisitorId] to save it.
  void updateVisitorId(String token, String visitorId) {
    _identityLoaded.add(token);
    _visitorId[token] = visitorId;
  }

  /// Best-effort save of the visitor ID (storage errors are logged).
  Future<void> persistVisitorId(String token) async {
    final visitorId = _visitorId[token];
    if (!_identityLoaded.contains(token) || visitorId == null) return;
    await storageAdapter.setItem(visitorIdKey(token), visitorId);
  }

  int _revision(String token) => _optOutRevision[token] ?? 0;

  static bool _isBooleanString(String? value) =>
      value == 'true' || value == 'false';

  /// Reads the stored tracking decision. Tracking stays closed while the
  /// read is pending and when it fails. A decision made in this process
  /// ([updateOptedOut]) wins over an older read.
  Future<void> loadOptOut(String token) async {
    final revision = _revision(token);
    if (revision > 0) return;
    _optOutLoaded[token] = false;
    _optedOut[token] = true;
    final optOutString = await storageAdapter.getItemStrict(optOutKey(token));
    if (revision != _revision(token)) return;
    if (optOutString != null && !_isBooleanString(optOutString)) {
      throw const OursPrivacyException('Invalid stored tracking decision');
    }
    final explicitDecision =
        await storageAdapter.getItemStrict(optOutDecisionKey(token));
    if (revision != _revision(token)) return;
    if (explicitDecision != null && !_isBooleanString(explicitDecision)) {
      throw const OursPrivacyException('Invalid stored tracking decision');
    }
    final defaultDecision =
        await storageAdapter.getItemStrict(optOutDefaultKey(token));
    if (revision != _revision(token)) return;
    if (defaultDecision != null && !_isBooleanString(defaultDecision)) {
      throw const OursPrivacyException('Invalid stored tracking default');
    }
    _storedOptOutDecision[token] = _isBooleanString(explicitDecision);
    _storedOptOutDefault[token] =
        defaultDecision != null && defaultDecision == optOutString;
    _optedOut[token] = optOutString == 'true' ||
        explicitDecision == 'true' ||
        (_storedOptOutDecision[token] != true && defaultDecision == 'true');
    _optOutLoaded[token] = true;
  }

  /// True while the decision is unknown (not loaded, or loading failed) or
  /// when tracking is opted out.
  bool getOptedOut(String token) =>
      _optOutLoaded[token] != true || _optedOut[token] == true;

  bool hasStoredOptOutDecision(String token) =>
      _storedOptOutDecision[token] == true;

  bool hasStoredOptOutDefault(String token) =>
      _storedOptOutDefault[token] == true;

  /// Sets the in-memory decision and returns the new revision. With
  /// [expectedRevision], the update only applies if no other update happened
  /// since that revision (used to roll back a failed opt-in); otherwise the
  /// current revision is returned unchanged.
  int updateOptedOut(String token, bool optOut, [int? expectedRevision]) {
    final currentRevision = _revision(token);
    if (expectedRevision != null && expectedRevision != currentRevision) {
      return currentRevision;
    }
    final revision = currentRevision + 1;
    _optOutRevision[token] = revision;
    _optedOut[token] = optOut;
    return revision;
  }

  /// Saves the in-memory decision. An explicit decision writes the legacy key
  /// and the decision key; a default writes the legacy key and the default
  /// key. Strict: storage failures propagate.
  Future<void> persistOptedOut(
    String token, {
    bool explicitDecision = true,
  }) async {
    final optedOut = _optedOut[token];
    if (optedOut == null) return;
    if (explicitDecision) {
      _storedOptOutDecision[token] = true;
      _storedOptOutDefault[token] = false;
    }
    await storageAdapter.setItemStrict(optOutKey(token), optedOut.toString());
    if (explicitDecision) {
      await storageAdapter.setItemStrict(
          optOutDecisionKey(token), optedOut.toString());
      _storedOptOutDecision[token] = true;
      _storedOptOutDefault[token] = false;
    } else {
      await storageAdapter.setItemStrict(
          optOutDefaultKey(token), optedOut.toString());
      _storedOptOutDefault[token] = true;
    }
    _optOutLoaded[token] = true;
  }

  /// Loads the stored queue. Returns the decoded value: a `List` of rows, a
  /// `Map` envelope with `items` plus the saved queue metadata merged in, or
  /// whatever other JSON value was stored (the queue manager normalizes it).
  /// An unreadable or unparseable queue yields an empty list; unreadable
  /// metadata yields the bare row list.
  Future<Object?> loadQueue(String token, String type) async {
    Object? queue;
    try {
      final queueString = await storageAdapter.getItemStrict(
        queueKey(token, type),
      );
      queue = queueString != null && queueString.isNotEmpty
          ? jsonDecode(queueString)
          : <Object?>[];
    } catch (_) {
      OursPrivacyLogger.error(
        token,
        'Saved event queue could not be read; starting an empty queue.',
      );
      return <Object?>[];
    }
    if (queue is! List) return queue;
    try {
      final metadataString = await storageAdapter.getItemStrict(
        queueMetadataKey(token, type),
      );
      final Object? metadata =
          metadataString != null && metadataString.isNotEmpty
              ? jsonDecode(metadataString)
              : <String, Object?>{};
      return <String, Object?>{
        if (metadata is Map)
          for (final entry in metadata.entries)
            if (entry.key is String) entry.key as String: entry.value,
        'items': queue,
      };
    } catch (_) {
      OursPrivacyLogger.error(
        token,
        'Saved queue metadata could not be read; preserving queued events.',
      );
      return queue;
    }
  }

  /// Saves the queue rows as a bare JSON array (readable by every SDK
  /// version). Strict: storage failures propagate.
  Future<void> saveQueue(String token, String type, List<Object?> items) =>
      storageAdapter.setItemStrict(queueKey(token, type), jsonEncode(items));

  /// Saves auxiliary queue metadata. Strict: storage failures propagate.
  Future<void> saveQueueMetadata(
    String token,
    String type,
    Map<String, Object?> metadata,
  ) =>
      storageAdapter.setItemStrict(
          queueMetadataKey(token, type), jsonEncode(metadata));

  /// Forgets the visitor ID (unless [preserveVisitorId]) and loads a new one.
  Future<void> reset(String token, {bool preserveVisitorId = false}) async {
    if (!preserveVisitorId) {
      await storageAdapter.removeItem(visitorIdKey(token));
      await loadIdentity(token);
    }
  }
}
