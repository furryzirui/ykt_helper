import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../domain/models.dart';

class AiRateLimitFailure extends ApiFailure {
  final Duration? retryAfter;
  const AiRateLimitFailure(String message, {this.retryAfter})
    : super(message, 429);

  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    final seconds = int.tryParse(text);
    if (seconds != null) {
      // Duration stores signed 64-bit microseconds on native targets. Reject
      // unrepresentable server values instead of overflowing to a short wait.
      return seconds < 0 || seconds > 9223372036854
          ? null
          : Duration(seconds: seconds);
    }
    try {
      final delay = HttpDate.parse(text).difference(now ?? DateTime.now());
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }
}

class AiGenerationCanceled implements Exception {
  const AiGenerationCanceled();
}

enum AiRequestPhase { queued, waiting, request, retry, retryExhausted }

class AiRequestProgress {
  final AiRequestPhase phase;
  final int retry;
  final Duration remaining;
  const AiRequestProgress(
    this.phase, {
    this.retry = 0,
    this.remaining = Duration.zero,
  });
}

class _AiRequest {
  final Future<String> Function() operation;
  final bool Function() isCurrent;
  final Duration Function() interval;
  final int Function() maxRetries;
  final void Function(AiRequestProgress) progress;
  final result = Completer<String>();
  final canceled = Completer<void>();
  CancelToken? activeToken;
  Timer? watcher;
  _AiRequest(
    this.operation,
    this.isCurrent,
    this.interval,
    this.maxRetries,
    this.progress,
  );

  int get retryLimit => maxRetries().clamp(0, 10);

  bool get valid => !canceled.isCompleted && isCurrent();

  void cancel() {
    if (canceled.isCompleted) return;
    canceled.complete();
    activeToken?.cancel('Generation is no longer current');
    if (!result.isCompleted) result.completeError(const AiGenerationCanceled());
  }

  void emit(AiRequestProgress value) {
    if (!valid) return;
    try {
      progress(value);
    } catch (_) {
      // A UI/log update must not fail or duplicate a provider request.
    }
  }
}

/// One FIFO for the whole process, including different classrooms/controllers.
/// Only AI generation enters this queue; answer submission is never retried here.
class AiRequestScheduler {
  static final shared = AiRequestScheduler();
  static final Object _cancellationZoneKey = Object();
  static final Object _trackedRequestZoneKey = Object();
  static CancelToken? get currentCancellationToken =>
      Zone.current[_cancellationZoneKey] as CancelToken?;
  static Future<T> trackTransport<T>(Future<T> request) {
    final track =
        Zone.current[_trackedRequestZoneKey] as void Function(Future<void>)?;
    track?.call(
      request.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return request;
  }

  static const _checkInterval = Duration(milliseconds: 300);
  final Duration Function() _elapsed;
  final Future<void> Function(Duration) _wait;
  AiRequestScheduler({
    Duration Function()? elapsed,
    Future<void> Function(Duration)? wait,
  }) : _elapsed = elapsed ?? _monotonicClock(),
       _wait = wait ?? _delay;

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  static Future<void> _delay(Duration duration) =>
      Future<void>.delayed(duration);
  static int _defaultRetries() => 3;
  final List<_AiRequest> _queue = [];
  bool _running = false;
  int? _lastRequestCompletedMs;
  int _rateLimitNotBeforeMs = 0;

  Future<String> generate({
    required Future<String> Function() request,
    required bool Function() isCurrent,
    required Duration Function() interval,
    int Function() maxRetries = _defaultRetries,
    required void Function(AiRequestProgress) onProgress,
  }) {
    final job = _AiRequest(
      request,
      isCurrent,
      interval,
      maxRetries,
      onProgress,
    );
    if (!job.valid) return Future.error(const AiGenerationCanceled());
    _queue.add(job);
    job.watcher = Timer.periodic(_checkInterval, (_) {
      if (!job.valid) job.cancel();
    });
    job.emit(const AiRequestProgress(AiRequestPhase.queued));
    if (!_running) unawaited(_drain());
    return job.result.future;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        try {
          if (!job.valid) {
            job.cancel();
            continue;
          }
          final value = await _execute(job);
          if (!job.result.isCompleted) job.result.complete(value);
        } catch (failure, trace) {
          if (!job.result.isCompleted) job.result.completeError(failure, trace);
        } finally {
          job.watcher?.cancel();
          job.activeToken = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<String> _execute(_AiRequest job) async {
    var retry = 0;
    var rateLimited = false;
    AiRateLimitFailure? lastRateLimit;
    while (true) {
      await _waitForSlot(job, retry, rateLimited, lastRateLimit);
      if (!job.valid) throw const AiGenerationCanceled();
      final token = CancelToken();
      job.activeToken = token;
      job.emit(AiRequestProgress(AiRequestPhase.request, retry: retry));
      Future<void>? transport;
      try {
        final request = runZoned(
          job.operation,
          zoneValues: {
            _cancellationZoneKey: token,
            _trackedRequestZoneKey: (Future<void> request) =>
                transport = request,
          },
        );
        return await Future.any<String>([
          request,
          job.canceled.future.then<String>(
            (_) => throw const AiGenerationCanceled(),
          ),
        ]);
      } on AiRateLimitFailure catch (failure) {
        if (!job.valid) throw const AiGenerationCanceled();
        lastRateLimit = failure;
        final backoff =
            failure.retryAfter ??
            Duration(
              seconds: retry == 0
                  ? 5
                  : retry == 1
                  ? 10
                  : 20,
            );
        final next = _elapsed().inMilliseconds + backoff.inMilliseconds;
        if (next > _rateLimitNotBeforeMs) _rateLimitNotBeforeMs = next;
        if (retry >= job.retryLimit) {
          job.emit(
            AiRequestProgress(AiRequestPhase.retryExhausted, retry: retry),
          );
          rethrow;
        }
        retry++;
        rateLimited = true;
      } finally {
        // Dio cancellation settles its tracked transport before the FIFO may
        // launch another HTTP request. Uncancelable fakes may finish later, but
        // their result is already ignored by the controller/session guard.
        if (transport != null) await transport;
        _lastRequestCompletedMs = _elapsed().inMilliseconds;
        job.activeToken = null;
      }
    }
  }

  Future<void> _waitForSlot(
    _AiRequest job,
    int retry,
    bool rateLimited,
    AiRateLimitFailure? lastRateLimit,
  ) async {
    var previousSeconds = -1;
    while (true) {
      if (!job.valid) {
        job.cancel();
        throw const AiGenerationCanceled();
      }
      if (lastRateLimit != null && retry > job.retryLimit) {
        job.emit(
          AiRequestProgress(AiRequestPhase.retryExhausted, retry: retry - 1),
        );
        throw lastRateLimit;
      }
      final gapMs = job.interval().inMilliseconds.clamp(0, 3600000);
      final intervalAt = (_lastRequestCompletedMs ?? -gapMs) + gapMs;
      final notBeforeMs = intervalAt > _rateLimitNotBeforeMs
          ? intervalAt
          : _rateLimitNotBeforeMs;
      final remainingMs = notBeforeMs - _elapsed().inMilliseconds;
      if (remainingMs <= 0) return;
      final seconds = (remainingMs / 1000).ceil();
      if (seconds != previousSeconds) {
        previousSeconds = seconds;
        job.emit(
          AiRequestProgress(
            rateLimited ? AiRequestPhase.retry : AiRequestPhase.waiting,
            retry: retry,
            remaining: Duration(milliseconds: remainingMs),
          ),
        );
      }
      await Future.any<void>([
        _wait(
          Duration(
            milliseconds: remainingMs < _checkInterval.inMilliseconds
                ? remainingMs
                : _checkInterval.inMilliseconds,
          ),
        ),
        job.canceled.future,
      ]);
    }
  }
}
