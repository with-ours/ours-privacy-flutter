// Port of javascript/oursprivacy-core.js (React Native SDK).
//
// Batches queued events, uploads them, and applies the server's
// acknowledgment:
// - a batch never mixes visitor IDs or identity modes, so each request
//   carries one `is_manually_set_id`;
// - an indexed response (`accepted` + `rejected[{index, code}]`) removes the
//   whole batch and reports only the rejected rows through `onIngestRejected`,
//   after the removal is durable;
// - `success: false` rejects the batch (`ingest_rejected`) unless
//   `retryable: true`, which keeps it;
// - a permanent 4xx removes and reports the batch as `http_<status>`;
// - a malformed acknowledgment keeps the batch, and the fifth malformed
//   acknowledgment for the same head event removes it as
//   `invalid_acknowledgment`;
// - opt-out (or dispose) bumps a generation counter and cancels in-flight
//   uploads; any result from an older generation is ignored.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'config.dart';
import 'constants.dart';
import 'device_info.dart';
import 'logger.dart';
import 'network.dart';
import 'persistent.dart';
import 'queue.dart';
import 'storage.dart';

/// Number of malformed acknowledgments for the same head event after which
/// its batch is dropped.
const int maxMalformedAcknowledgments = 5;

final Map<OursPrivacyStorage, Map<String, Future<void>>> _pendingFlushes =
    Map.identity();

const int _maxSafeInteger = 9007199254740991;

/// JavaScript `Number.isSafeInteger` for decoded JSON.
int? _safeInteger(Object? value) {
  if (value is int) {
    return value.abs() <= _maxSafeInteger ? value : null;
  }
  if (value is double &&
      value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() <= _maxSafeInteger) {
    return value.toInt();
  }
  return null;
}

bool _hasIndexedResult(Map<Object?, Object?> response) =>
    response.containsKey('accepted') || response.containsKey('rejected');

typedef _Rejection = ({int index, String code});

List<_Rejection> _rejectedFromMobileResponse(
  Map<Object?, Object?> response,
  int batchSize,
) {
  const invalid = OursPrivacyInvalidAcknowledgment(
    'Invalid mobile ingest response',
  );
  final accepted = _safeInteger(response['accepted']);
  final rejected = response['rejected'];
  if (response['success'] != true ||
      accepted == null ||
      accepted < 0 ||
      rejected is! List ||
      accepted + rejected.length != batchSize) {
    throw invalid;
  }
  final indexes = <int>{};
  final result = <_Rejection>[];
  for (final item in rejected) {
    if (item is! Map) throw invalid;
    final index = _safeInteger(item['index']);
    final code = item['code'];
    if (index == null ||
        index < 0 ||
        index >= batchSize ||
        code is! String ||
        code.trim().isEmpty ||
        indexes.contains(index)) {
      throw invalid;
    }
    indexes.add(index);
    result.add((index: index, code: code));
  }
  return result;
}

/// Test hook: resets every process-wide registry owned by the foundation
/// modules (shared persistence and queues per storage, pending flush chains,
/// the shared network and its in-flight requests, per-token config, and the
/// device-info override).
@visibleForTesting
void resetOursPrivacyFoundationForTesting() {
  OursPrivacyCore.resetForTesting();
  OursPrivacyQueueManager.resetForTesting();
  OursPrivacyPersistent.resetForTesting();
  OursPrivacyNetwork.resetForTesting();
  OursPrivacyConfig.instance.resetForTesting();
  OursPrivacyDeviceInfo.resetForTesting();
}

/// One SDK instance's upload engine. React Native creates one per
/// `OursPrivacyMain`; the queue, persistence and network it uses are shared
/// process-wide (per storage backend).
class OursPrivacyCore {
  OursPrivacyCore({
    OursPrivacyStorage? storage,
    OursPrivacyNetwork? network,
    this.httpClient,
    OursPrivacyTimerFactory? timerFactory,
  })  : persistent = OursPrivacyPersistent.of(storage),
        queueManager = OursPrivacyQueueManager.of(storage),
        _network = network,
        timerFactory = timerFactory ?? Timer.new;

  /// Test hook: forget the process-wide pending-flush chains.
  static void resetForTesting() => _pendingFlushes.clear();

  final OursPrivacyPersistent persistent;
  final OursPrivacyQueueManager queueManager;

  /// Host-owned HTTP client passed to every request; never closed by the
  /// SDK. When null, the network creates and closes its own clients.
  final http.Client? httpClient;

  /// Creates the flush timer. Injectable for tests (fake_async also works).
  final OursPrivacyTimerFactory timerFactory;

  final OursPrivacyNetwork? _network;
  OursPrivacyNetwork get network => _network ?? OursPrivacyNetwork.shared;

  OursPrivacyConfig get _config => OursPrivacyConfig.instance;

  bool _isProcessingQueue = false;
  Timer? _processQueueTimer;
  bool _disposed = false;
  int _privacyGeneration = 0;
  String? _malformedBatchKey;
  int _malformedAttempts = 0;

  /// True after [stopProcessingQueue].
  bool get isDisposed => _disposed;

  /// Incremented by [cancelPendingUploads]; for tests.
  @visibleForTesting
  int get privacyGeneration => _privacyGeneration;

  /// True while a periodic flush is scheduled or running.
  @visibleForTesting
  bool get isProcessingQueue => _isProcessingQueue;

  bool _shouldLog(String token) =>
      oursPrivacyLogSink != null || _config.getLoggingEnabled(token);

  /// Loads the stored event queue.
  Future<void> initialize(String token) =>
      queueManager.initialize(token, eventsQueueType);

  /// Starts the periodic flush (every `getFlushInterval(token)`), unless
  /// tracking is opted out, the core is disposed, or a cycle is already
  /// scheduled.
  void startProcessingQueue(String token) {
    if (_disposed || persistent.getOptedOut(token)) {
      OursPrivacyLogger.log(
        token,
        'User has opted out of tracking, skipping processing queue.',
      );
      return;
    }

    if (_isProcessingQueue) {
      OursPrivacyLogger.log(
        token,
        'Queue is already being processed. Skipping new cycle.',
      );
      return;
    }

    _isProcessingQueue = true;

    _processQueueTimer = timerFactory(_config.getFlushInterval(token), () {
      _processQueueTimer = null;
      unawaited(() async {
        try {
          await _processQueue(token, eventsQueueType);
        } catch (error) {
          OursPrivacyLogger.error(token, 'Error processing queue: $error');
        }
        _isProcessingQueue = false;
        startProcessingQueue(token);
      }());
    });
  }

  /// Permanently stops this core: no further periodic or explicit uploads.
  void stopProcessingQueue() {
    _disposed = true;
    _processQueueTimer?.cancel();
    _processQueueTimer = null;
  }

  /// Ignores every upload result from before this call and cancels in-flight
  /// requests and retries for [token] (across all cores).
  void cancelPendingUploads(String token) {
    _privacyGeneration += 1;
    _malformedBatchKey = null;
    _malformedAttempts = 0;
    network.cancelRequests(token);
  }

  /// Enqueues [data] unless tracking is opted out or [data] is not
  /// JSON-encodable. Returns whether it was queued. Storage failures of the
  /// row write propagate.
  Future<bool> addToOursPrivacyQueue(
    String token,
    String type,
    Map<String, Object?> data,
  ) async {
    if (persistent.getOptedOut(token)) {
      OursPrivacyLogger.log(
        token,
        'User has opted out of tracking, skipping tracking.',
      );
      return false;
    }
    final String encoded;
    try {
      encoded = jsonEncode(data);
    } catch (error) {
      OursPrivacyLogger.error(token, 'Error in OursPrivacy payload: $error');
      OursPrivacyLogger.error(
        token,
        'The OursPrivacy payload is not valid or not serializable.',
      );
      return false;
    }
    await queueManager.enqueue(token, type, data);
    if (_shouldLog(token)) {
      OursPrivacyLogger.log(token, "Event added to queue. Payload: '$encoded'");
    }
    return true;
  }

  /// Uploads the queue now (after any flush already running for this queue).
  Future<void> flush(String token) async {
    if (persistent.getOptedOut(token)) {
      OursPrivacyLogger.log(
        token,
        'User has opted out of tracking, do not flush queue.',
      );
      return;
    }
    await _processQueue(token, eventsQueueType);
  }

  bool _stale(String token, int generation) =>
      _disposed ||
      generation != _privacyGeneration ||
      persistent.getOptedOut(token);

  Future<void> _processQueue(String token, String type) {
    final generation = _privacyGeneration;
    final key = '$token:$type';
    final chains = _pendingFlushes.putIfAbsent(
      persistent.storage,
      () => <String, Future<void>>{},
    );
    final result = (chains[key] ?? Future<void>.value()).then((_) async {
      if (_disposed || generation != _privacyGeneration) return;
      OursPrivacyLogger.log(token, 'Processing queue for endpoint: $type');
      while (!_stale(token, generation)) {
        final queue = queueManager.getQueue(token, type);
        if (queue.isEmpty) return;
        OursPrivacyLogger.log(token, '[Flushing queue] endpoint: $type');
        if (_shouldLog(token)) {
          OursPrivacyLogger.log(
            token,
            '[Flushing queue] queue: ${jsonEncode(queue)}',
          );
        }
        final batchSize = _config.getFlushBatchSize(token);
        final fallbackIdentityMode = _config.getIsManuallySetId(token);
        bool identityMode(QueueItem item) {
          final mode = item['isManuallySetId'];
          return mode is bool ? mode : fallbackIdentityMode;
        }

        final head = queue.first;
        final isManuallySetId = identityMode(head);
        final batch = <QueueItem>[];
        for (final item in queue.take(batchSize)) {
          if (item['visitor_id'] != head['visitor_id'] ||
              identityMode(item) != isManuallySetId) {
            break;
          }
          batch.add(item);
        }
        final batchKey = jsonEncode([token, generation, head['distinct_id']]);
        if (_malformedBatchKey != batchKey) {
          _malformedBatchKey = batchKey;
          _malformedAttempts = 0;
        }

        Future<void> removeBatch(
          List<_Rejection> rejected, [
          OursPrivacyResponseMode? responseMode,
        ]) async {
          if (_stale(token, generation)) return;
          await queueManager.removeByIds(
            token,
            type,
            batch.map((item) => item['distinct_id']),
            responseMode,
          );
          _malformedBatchKey = null;
          _malformedAttempts = 0;
          if (_stale(token, generation)) return;
          final onIngestRejected = _config.getOnIngestRejected(token);
          if (onIngestRejected == null) return;
          for (final rejection in rejected) {
            if (_stale(token, generation)) return;
            final distinctId = batch[rejection.index]['distinct_id'];
            _invokeRejectionCallback(
              token,
              onIngestRejected,
              OursPrivacyIngestRejection(
                distinctId: distinctId is String
                    ? distinctId
                    : (distinctId?.toString() ?? ''),
                code: rejection.code,
              ),
            );
          }
        }

        try {
          final response = await network.sendRequest(
            token: token,
            data: [
              for (final item in batch)
                Map<String, Object?>.of(item)..remove('isManuallySetId'),
            ],
            endpoint: type,
            serverURL: _config.getServerURL(token),
            isManuallySetId: isManuallySetId,
            client: httpClient,
          );
          if (_stale(token, generation)) return;
          if (response is! Map) {
            throw const OursPrivacyInvalidAcknowledgment(
              'Invalid mobile ingest response',
            );
          }
          var rejected = <_Rejection>[];
          OursPrivacyResponseMode? responseMode;
          if (response['success'] == false) {
            if (response['retryable'] == true) return;
            rejected = [
              for (var index = 0; index < batch.length; index++)
                (index: index, code: 'ingest_rejected'),
            ];
          } else if (_hasIndexedResult(response)) {
            rejected = _rejectedFromMobileResponse(response, batch.length);
            responseMode = OursPrivacyResponseMode.indexed;
          } else {
            responseMode = OursPrivacyResponseMode.legacy;
          }
          await removeBatch(rejected, responseMode);
        } catch (error) {
          if (_stale(token, generation)) return;
          final code = error is OursPrivacyHttpError ? error.code : null;
          final permanent = isPermanentHttpStatus(code);
          final invalidAcknowledgment =
              error is OursPrivacyInvalidAcknowledgment;
          if (invalidAcknowledgment) _malformedAttempts += 1;
          if (permanent ||
              (invalidAcknowledgment &&
                  _malformedAttempts >= maxMalformedAcknowledgments)) {
            try {
              await removeBatch([
                for (var index = 0; index < batch.length; index++)
                  (
                    index: index,
                    code: permanent ? 'http_$code' : 'invalid_acknowledgment',
                  ),
              ]);
              continue;
            } catch (saveError) {
              OursPrivacyLogger.error(
                token,
                'Failed to save rejected batch removal: $saveError',
              );
              return;
            }
          }
          OursPrivacyLogger.error(
            token,
            'Error sending event batch from queue, error: $error',
          );
          return;
        }
      }
    });
    chains[key] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _invokeRejectionCallback(
    String token,
    OursPrivacyIngestRejectedCallback callback,
    OursPrivacyIngestRejection rejection,
  ) {
    void report(Object _) =>
        OursPrivacyLogger.error(token, 'onIngestRejected callback failed');
    try {
      // An `async` callback returns a Future through the void signature;
      // observe it so its failure is logged instead of escaping to the zone.
      // ignore: void_checks
      final Object? result = callback(rejection) as Object?;
      if (result is Future<Object?>) {
        unawaited(result.then<void>((_) {}, onError: report));
      }
    } catch (error) {
      report(error);
    }
  }
}
