// Port of javascript/oursprivacy-network.js (React Native SDK).
//
// POSTs a batch to `${serverURL}${endpoint}` and retries transient failures
// with exponential backoff (2 s, 4 s, 8 s, 16 s, 32 s; capped at 60 s).
//
// Cancellation (opt-out, re-init) replaces React Native's AbortController:
// - every in-flight attempt races a per-request cancel signal, so a cancelled
//   upload settles immediately even if the HTTP client cannot abort;
// - an SDK-owned client (from [OursPrivacyNetwork.clientFactory]) is closed to
//   tear down its socket; a host-injected client is never closed;
// - a pending backoff timer is cancelled.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'logger.dart';

/// An HTTP failure. [code] is the HTTP status, or null for transport errors.
class OursPrivacyHttpError implements Exception {
  OursPrivacyHttpError(this.message, this.code);

  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// Thrown when a request was cancelled after a tracking opt-out (or dispose).
class OursPrivacyRequestCancelledError implements Exception {
  const OursPrivacyRequestCancelledError();

  String get message => 'Request cancelled after tracking opt-out';

  @override
  String toString() => message;
}

/// The server answered 2xx with a body that is not a usable acknowledgment
/// (unparseable JSON, a non-object, or a malformed indexed result). Never
/// retried by the network layer; the core caps it at five flushes per head.
class OursPrivacyInvalidAcknowledgment implements Exception {
  const OursPrivacyInvalidAcknowledgment(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Statuses in 400..499 that are still retried (and never treated as a
/// permanent rejection).
const Set<int> retryableClientStatuses = {403, 408, 425, 429};

/// True for a 4xx status that means the batch can never be accepted.
bool isPermanentHttpStatus(int? code) =>
    code != null &&
    code >= 400 &&
    code < 500 &&
    !retryableClientStatuses.contains(code);

/// Maximum number of retries after the first attempt.
const int networkMaxRetries = 5;

/// Maximum 307/308 redirects followed within one attempt (fetch's limit).
const int networkMaxRedirects = 20;

/// Backoff before retry number `count + 1`.
Duration networkBackoff(int count) {
  final ms = (1 << count) * 2000;
  return Duration(milliseconds: ms < 60000 ? ms : 60000);
}

typedef OursPrivacyTimerFactory = Timer Function(
    Duration duration, void Function() callback);

class _ActiveRequest {
  _ActiveRequest(this.ownedClient);

  final http.Client? ownedClient;
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get onCancel => _cancelled.future;

  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    try {
      ownedClient?.close();
    } catch (_) {}
  }
}

class OursPrivacyNetwork {
  OursPrivacyNetwork({
    http.Client Function()? clientFactory,
    OursPrivacyTimerFactory? timerFactory,
  })  : clientFactory = clientFactory ?? http.Client.new,
        timerFactory = timerFactory ?? Timer.new;

  /// Process-wide network used by default. Like React Native's module-level
  /// `OursPrivacyNetwork`, it tracks active requests per token so that
  /// [cancelRequests] reaches uploads started by any SDK instance.
  static OursPrivacyNetwork shared = OursPrivacyNetwork();

  /// Test hook: replace [shared] with a fresh default network.
  static void resetForTesting() {
    for (final requests in shared._activeRequests.values) {
      for (final request in requests.toList()) {
        request.cancel();
      }
    }
    shared = OursPrivacyNetwork();
  }

  /// Creates the SDK-owned client used when no host client is passed to
  /// [sendRequest]. The SDK closes clients it created.
  final http.Client Function() clientFactory;

  /// Creates backoff timers. Injectable for tests (fake_async also works).
  final OursPrivacyTimerFactory timerFactory;

  final Map<String, Set<_ActiveRequest>> _activeRequests = {};

  /// Number of in-flight requests for [token]; for tests.
  @visibleForTesting
  int activeRequestCount(String token) => _activeRequests[token]?.length ?? 0;

  /// Cancels every in-flight request and pending retry for [token].
  void cancelRequests(String token) {
    for (final request in (_activeRequests[token] ?? const {}).toList()) {
      request.cancel();
    }
  }

  Future<void> _waitForRetry(Duration duration, _ActiveRequest request) {
    if (request.isCancelled) {
      return Future.error(const OursPrivacyRequestCancelledError());
    }
    final completer = Completer<void>();
    final timer = timerFactory(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    unawaited(request.onCancel.then((_) {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.completeError(const OursPrivacyRequestCancelledError());
      }
    }));
    return completer.future;
  }

  /// Waits for [future] unless [request] is cancelled first.
  Future<T> _raceCancel<T>(Future<T> future, _ActiveRequest request) {
    final completer = Completer<T>();
    unawaited(future.then((value) {
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }));
    unawaited(request.onCancel.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const OursPrivacyRequestCancelledError());
      }
    }));
    return completer.future;
  }

  /// Sends one batch. Resolves with the decoded JSON body (`{}` for an empty
  /// body) on a 2xx response.
  ///
  /// Throws:
  /// - [OursPrivacyRequestCancelledError] after [cancelRequests];
  /// - [OursPrivacyInvalidAcknowledgment] when a 2xx body is not JSON;
  /// - [OursPrivacyHttpError] immediately for a permanent 4xx, or after
  ///   [networkMaxRetries] retries for anything else.
  ///
  /// [client] is a host-owned client and is never closed; when null, one is
  /// created with [clientFactory] and closed when the request settles.
  Future<Object?> sendRequest({
    required String token,
    required String endpoint,
    required List<Object?> data,
    required String serverURL,
    bool isManuallySetId = false,
    int retryCount = 0,
    http.Client? client,
  }) async {
    final url = '$serverURL$endpoint';
    // Encoded once; the body is identical on every retry. Sent as bytes so
    // package:http does not append `; charset=utf-8` to the content type.
    final body = utf8.encode(jsonEncode({
      'token': token,
      'is_manually_set_id': isManuallySetId,
      'data': data,
    }));
    final ownedClient = client == null ? clientFactory() : null;
    final httpClient = client ?? ownedClient!;
    final request = _ActiveRequest(ownedClient);
    final requests = _activeRequests.putIfAbsent(token, () => {});
    requests.add(request);

    Future<Object?> attempt(int count) async {
      if (request.isCancelled) throw const OursPrivacyRequestCancelledError();
      OursPrivacyLogger.log(token, 'Sending request to: $url');
      try {
        var target = Uri.parse(url);
        http.Response response;
        for (var redirects = 0;; redirects++) {
          response = await _raceCancel(
            httpClient.post(
              target,
              headers: const {'Content-Type': 'application/json'},
              body: body,
            ),
            request,
          );
          if (request.isCancelled) {
            throw const OursPrivacyRequestCancelledError();
          }
          // fetch re-sends a POST and its body on 307/308; dart:io follows
          // a POST redirect only on 303, so follow these here.
          final location = response.headers['location'];
          if ((response.statusCode == 307 || response.statusCode == 308) &&
              location != null &&
              location.isNotEmpty &&
              redirects < networkMaxRedirects) {
            target = target.resolve(location);
            continue;
          }
          break;
        }
        final status = response.statusCode;
        if (status < 200 || status > 299) {
          throw OursPrivacyHttpError('HTTP error! status: $status', status);
        }
        var responseText =
            utf8.decode(response.bodyBytes, allowMalformed: true);
        // fetch's Response.text() drops a leading byte-order mark.
        if (responseText.startsWith('﻿')) {
          responseText = responseText.substring(1);
        }
        Object? responseBody;
        try {
          responseBody = responseText == ''
              ? <String, Object?>{}
              : jsonDecode(responseText);
        } catch (error) {
          throw OursPrivacyInvalidAcknowledgment(
              'Invalid mobile ingest response', error);
        }
        OursPrivacyLogger.log(
          token,
          'OursPrivacy batch sent successfully, endpoint: $endpoint',
        );
        return responseBody;
      } catch (error) {
        if (request.isCancelled) {
          throw const OursPrivacyRequestCancelledError();
        }
        if (error is OursPrivacyInvalidAcknowledgment) rethrow;
        final code = error is OursPrivacyHttpError ? error.code : null;
        if (isPermanentHttpStatus(code)) {
          throw OursPrivacyHttpError('HTTP error! status: $code', code);
        }
        OursPrivacyLogger.warn(
          token,
          'API request to $url has failed with reason: '
          '${error is OursPrivacyHttpError ? error.message : error}',
        );
        final backoff = networkBackoff(count);
        if (count < networkMaxRetries) {
          OursPrivacyLogger.log(
            token,
            'Retrying in ${backoff.inMilliseconds ~/ 1000} seconds...',
          );
          await _waitForRetry(backoff, request);
          return attempt(count + 1);
        }
        OursPrivacyLogger.warn(token, 'Max retries reached. Giving up.');
        throw OursPrivacyHttpError('HTTP error! status: $code', code);
      }
    }

    try {
      return await attempt(retryCount);
    } finally {
      requests.remove(request);
      if (requests.isEmpty && identical(_activeRequests[token], requests)) {
        _activeRequests.remove(token);
      }
      if (ownedClient != null && !request.isCancelled) {
        try {
          ownedClient.close();
        } catch (_) {}
      }
    }
  }
}
