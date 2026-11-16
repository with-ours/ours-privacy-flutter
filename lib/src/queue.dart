// Port of javascript/oursprivacy-queue.js (React Native SDK).
//
// The durable event queue. One shared manager per storage backend; within
// it, one queue per (token, type). Every mutation runs on a per-(token, type)
// chain, persists the rows first and only then updates memory, so a failed
// write leaves both the stored and the in-memory queue unchanged.
//
// Queue metadata (`firstOpenAccepted`, `responseMode`) lives under its own
// key so the row key stays a bare JSON array that older SDKs can read.
import 'dart:async';

import 'logger.dart';
import 'mobile_payload.dart';
import 'persistent.dart';
import 'storage.dart';

/// How the server last acknowledged a batch for this queue.
enum OursPrivacyResponseMode {
  /// `{success, accepted, rejected: [{index, code}]}`.
  indexed,

  /// Any other successful body (for example `{success: true}` or empty).
  legacy;

  static OursPrivacyResponseMode? parse(Object? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// A queued event row: the JSON map persisted and uploaded (minus the
/// queue-internal `isManuallySetId`).
typedef QueueItem = Map<String, Object?>;

class _QueueState {
  const _QueueState({
    required this.items,
    required this.firstOpenAccepted,
    required this.responseMode,
  });

  final List<QueueItem> items;
  final bool firstOpenAccepted;
  final OursPrivacyResponseMode? responseMode;

  _QueueState copyWith({
    List<QueueItem>? items,
    bool? firstOpenAccepted,
    OursPrivacyResponseMode? responseMode,
  }) =>
      _QueueState(
        items: items ?? this.items,
        firstOpenAccepted: firstOpenAccepted ?? this.firstOpenAccepted,
        responseMode: responseMode ?? this.responseMode,
      );
}

bool _isFirstOpen(Object? item) =>
    item is Map && item['event'] == r'$mobile_first_open';

/// JavaScript truthiness for a `distinct_id` value.
bool _truthy(Object? value) =>
    value != null &&
    value != false &&
    value != '' &&
    !(value is num && (value == 0 || value.isNaN));

final Map<OursPrivacyStorage, OursPrivacyQueueManager> _managers =
    Map.identity();

class OursPrivacyQueueManager {
  OursPrivacyQueueManager._(this.persistent);

  /// The shared manager for [storage] (null means the default backend).
  static OursPrivacyQueueManager of(OursPrivacyStorage? storage) {
    final persistent = OursPrivacyPersistent.of(storage);
    return _managers.putIfAbsent(
        persistent.storage, () => OursPrivacyQueueManager._(persistent));
  }

  /// Test hook: forget every shared manager and its in-memory queues.
  static void resetForTesting() => _managers.clear();

  final OursPrivacyPersistent persistent;
  final Map<String, Map<String, _QueueState>> _queues = {};
  final Map<String, Future<void>> _pending = {};

  _QueueState? _get(String token, String type) => _queues[token]?[type];

  void _set(String token, String type, _QueueState queue) =>
      (_queues[token] ??= {})[type] = queue;

  static _QueueState _normalize([Object? stored]) {
    final Object? envelopeItems = stored is Map ? stored['items'] : null;
    final List<Object?> rawItems = stored is List
        ? stored
        : envelopeItems is List
            ? envelopeItems
            : const <Object?>[];
    final items = <QueueItem>[];
    for (final item in rawItems) {
      // Rows that are not JSON objects cannot be uploaded; drop them.
      if (item is! Map) continue;
      final normalized = normalizeMobilePayload(item);
      if (normalized is Map<String, Object?>) {
        items.add(normalized);
      } else if (normalized is Map) {
        items.add({
          for (final entry in normalized.entries)
            if (entry.key is String) entry.key as String: entry.value,
        });
      }
    }
    final mode = stored is Map ? stored['responseMode'] : null;
    return _QueueState(
      items: items,
      firstOpenAccepted:
          (stored is Map && stored['firstOpenAccepted'] == true) ||
              rawItems.any(_isFirstOpen),
      responseMode: OursPrivacyResponseMode.parse(mode),
    );
  }

  Future<T> _serialize<T>(
    String token,
    String type,
    Future<T> Function() action,
  ) {
    final key = '$token:$type';
    final result =
        (_pending[key] ?? Future<void>.value()).then((_) => action());
    _pending[key] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _save(String token, String type, _QueueState queue) async {
    await persistent.saveQueue(token, type, queue.items);
    _set(token, type, queue);
    try {
      await persistent.saveQueueMetadata(token, type, {
        'firstOpenAccepted': queue.firstOpenAccepted,
        'responseMode': queue.responseMode?.name,
      });
    } catch (_) {
      OursPrivacyLogger.error(
        token,
        'Queue metadata could not be saved; retaining the durable event queue.',
      );
    }
  }

  /// Loads the stored queue for (token, type) once per process.
  Future<void> initialize(String token, String type) =>
      _serialize(token, type, () async {
        if (_get(token, type) == null) {
          _set(
              token, type, _normalize(await persistent.loadQueue(token, type)));
        }
      });

  /// Appends [data] (normalized to the mobile contract) unless a row with the
  /// same truthy `distinct_id` is already queued. A duplicate
  /// `$mobile_first_open` still records first-open acceptance.
  Future<void> enqueue(String token, String type, QueueItem data) =>
      _serialize(token, type, () async {
        final queue = _get(token, type) ?? _normalize();
        final distinctId = data['distinct_id'];
        final duplicate = _truthy(distinctId) &&
            queue.items.any((item) => item['distinct_id'] == distinctId);
        if (duplicate && (queue.firstOpenAccepted || !_isFirstOpen(data))) {
          return;
        }
        await _save(
          token,
          type,
          queue.copyWith(
            items: duplicate
                ? queue.items
                : [...queue.items, normalizeMobileEvent(data)],
            firstOpenAccepted: queue.firstOpenAccepted || _isFirstOpen(data),
          ),
        );
      });

  /// A shallow copy of the in-memory rows (empty before [initialize]).
  List<QueueItem> getQueue(String token, String type) =>
      List.of(_get(token, type)?.items ?? const <QueueItem>[]);

  /// True once a `$mobile_first_open` has been durably queued for this
  /// install (even if it has since been uploaded).
  bool hasAcceptedFirstOpen(String token, String type) =>
      _get(token, type)?.firstOpenAccepted == true;

  OursPrivacyResponseMode? getResponseMode(String token, String type) =>
      _get(token, type)?.responseMode;

  /// Removes [deleteCount] rows starting at [start] (JavaScript `splice`
  /// semantics for in-range arguments).
  Future<void> spliceQueue(
    String token,
    String type,
    int start,
    int deleteCount,
  ) =>
      _serialize(token, type, () async {
        final queue = _get(token, type);
        if (queue == null) return;
        final items = List.of(queue.items);
        final length = items.length;
        final from = start < 0
            ? (length + start).clamp(0, length)
            : start.clamp(0, length);
        final to = (from + (deleteCount < 0 ? 0 : deleteCount)).clamp(
          from,
          length,
        );
        items.removeRange(from, to);
        await _save(token, type, queue.copyWith(items: items));
      });

  /// Removes every row whose `distinct_id` is in [ids] and, when given,
  /// records [responseMode].
  Future<void> removeByIds(
    String token,
    String type,
    Iterable<Object?> ids, [
    OursPrivacyResponseMode? responseMode,
  ]) =>
      _serialize(token, type, () async {
        final queue = _get(token, type);
        if (queue == null) return;
        final sentIds = ids.toSet();
        await _save(
          token,
          type,
          queue.copyWith(
            items: queue.items
                .where((item) => !sentIds.contains(item['distinct_id']))
                .toList(),
            responseMode: responseMode,
          ),
        );
      });

  /// Removes every row, keeping first-open acceptance and response mode.
  Future<void> clearQueue(String token, String type) =>
      _serialize(token, type, () async {
        await _save(
          token,
          type,
          (_get(token, type) ?? _normalize()).copyWith(items: []),
        );
      });
}
