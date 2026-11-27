import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_request_scheduler.dart';

class _Result {
  String? value;
  Object? error;
  bool done = false;
  _Result(Future<String> future) {
    future.then(
      (result) {
        value = result;
        done = true;
      },
      onError: (Object failure) {
        error = failure;
        done = true;
      },
    );
  }
}

AiRequestScheduler _scheduler(FakeAsync clock) => AiRequestScheduler(
  elapsed: () => clock.elapsed,
  wait: (delay) => Future<void>.delayed(delay),
);

void main() {
  test('FIFO is serial across jobs and interval starts after completion', () {
    fakeAsync((clock) {
      final queue = _scheduler(clock);
      final firstReply = Completer<String>();
      final starts = <Duration>[];
      final first = _Result(
        queue.generate(
          request: () {
            starts.add(clock.elapsed);
            return firstReply.future;
          },
          isCurrent: () => true,
          interval: () => const Duration(seconds: 3),
          onProgress: (_) {},
        ),
      );
      final second = _Result(
        queue.generate(
          request: () async {
            starts.add(clock.elapsed);
            return 'second';
          },
          isCurrent: () => true,
          interval: () => const Duration(seconds: 3),
          onProgress: (_) {},
        ),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 8));
      expect(starts, [Duration.zero]);
      firstReply.complete('first');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 2));
      expect(second.done, isFalse);
      clock.elapse(const Duration(seconds: 1));
      expect(starts, [Duration.zero, const Duration(seconds: 11)]);
      expect(first.value, 'first');
      expect(second.value, 'second');
      expect(clock.periodicTimerCount, 0);
    });
  });

  test(
    'zero interval remains serial and changes while waiting are respected',
    () {
      fakeAsync((clock) {
        final queue = _scheduler(clock);
        var gap = 10;
        final first = _Result(
          queue.generate(
            request: () async => 'first',
            isCurrent: () => true,
            interval: () => Duration(seconds: gap),
            onProgress: (_) {},
          ),
        );
        final second = _Result(
          queue.generate(
            request: () async => 'second',
            isCurrent: () => true,
            interval: () => Duration(seconds: gap),
            onProgress: (_) {},
          ),
        );
        clock.flushMicrotasks();
        expect(first.done, isTrue);
        expect(second.done, isFalse);
        gap = 0;
        clock.elapse(const Duration(milliseconds: 300));
        expect(second.value, 'second');
      });
    },
  );

  for (final limit in [0, 1, 3, 5]) {
    test(
      '429 maxRetries=$limit is additional attempts with capped exponential waits',
      () {
        fakeAsync((clock) {
          final queue = _scheduler(clock);
          final starts = <Duration>[];
          final phases = <AiRequestProgress>[];
          final result = _Result(
            queue.generate(
              request: () async {
                starts.add(clock.elapsed);
                throw const AiRateLimitFailure('limited');
              },
              isCurrent: () => true,
              interval: () => Duration.zero,
              maxRetries: () => limit,
              onProgress: phases.add,
            ),
          );
          clock.flushMicrotasks();
          clock.elapse(const Duration(minutes: 3));
          final expected = <Duration>[Duration.zero];
          var elapsed = Duration.zero;
          for (var retry = 0; retry < limit; retry++) {
            elapsed += Duration(
              seconds: retry == 0
                  ? 5
                  : retry == 1
                  ? 10
                  : 20,
            );
            expected.add(elapsed);
          }
          expect(starts, expected);
          expect(result.error, isA<AiRateLimitFailure>());
          expect(phases.last.phase, AiRequestPhase.retryExhausted);
          expect(phases.last.retry, limit);
          expect(clock.periodicTimerCount, 0);
        });
      },
    );
  }

  test('retry limit uses runtime clamps and can be reduced during backoff', () {
    fakeAsync((clock) {
      final queue = _scheduler(clock);
      var limit = 100;
      var requests = 0;
      final result = _Result(
        queue.generate(
          request: () async {
            requests++;
            throw const AiRateLimitFailure('limited');
          },
          isCurrent: () => true,
          interval: () => Duration.zero,
          maxRetries: () => limit,
          onProgress: (_) {},
        ),
      );
      clock.flushMicrotasks();
      limit = -5;
      clock.elapse(const Duration(milliseconds: 300));
      expect(requests, 1);
      expect(result.error, isA<AiRateLimitFailure>());
    });
    fakeAsync((clock) {
      final queue = _scheduler(clock);
      var requests = 0;
      final result = _Result(
        queue.generate(
          request: () async {
            requests++;
            throw const AiRateLimitFailure('limited');
          },
          isCurrent: () => true,
          interval: () => Duration.zero,
          maxRetries: () => 100,
          onProgress: (_) {},
        ),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 4));
      expect(requests, 11);
      expect(result.error, isA<AiRateLimitFailure>());
    });
  });

  test(
    'raising the retry limit during backoff permits the additional retry',
    () {
      fakeAsync((clock) {
        final queue = _scheduler(clock);
        var limit = 1;
        final starts = <Duration>[];
        final result = _Result(
          queue.generate(
            request: () async {
              starts.add(clock.elapsed);
              throw const AiRateLimitFailure('limited');
            },
            isCurrent: () => true,
            interval: () => Duration.zero,
            maxRetries: () => limit,
            onProgress: (_) {},
          ),
        );
        clock.flushMicrotasks();
        limit = 2;
        clock.elapse(const Duration(seconds: 15));
        expect(starts, [
          Duration.zero,
          const Duration(seconds: 5),
          const Duration(seconds: 15),
        ]);
        expect(result.error, isA<AiRateLimitFailure>());
        expect(clock.periodicTimerCount, 0);
      });
    },
  );

  test('Retry-After seconds and HTTP dates parse safely', () {
    final date = DateTime.utc(2026, 11, 27, 10);
    expect(AiRateLimitFailure.parseRetryAfter('7'), const Duration(seconds: 7));
    expect(
      AiRateLimitFailure.parseRetryAfter(
        HttpDate.format(date.add(const Duration(seconds: 9))),
        now: date,
      ),
      const Duration(seconds: 9),
    );
    expect(
      AiRateLimitFailure.parseRetryAfter(
        HttpDate.format(date.subtract(const Duration(seconds: 1))),
        now: date,
      ),
      Duration.zero,
    );
    for (final invalid in [
      null,
      '',
      '-1',
      'nonsense',
      '9223372036855',
      '999999999999999999999999999',
    ]) {
      expect(AiRateLimitFailure.parseRetryAfter(invalid), isNull);
    }
  });

  test(
    'Retry-After overrides fallback and exhaustion lets later work continue after cooldown',
    () {
      fakeAsync((clock) {
        final queue = _scheduler(clock);
        var calls = 0;
        final first = _Result(
          queue.generate(
            request: () async {
              calls++;
              throw const AiRateLimitFailure(
                'limited',
                retryAfter: Duration(seconds: 7),
              );
            },
            isCurrent: () => true,
            interval: () => Duration.zero,
            maxRetries: () => 1,
            onProgress: (_) {},
          ),
        );
        final starts = <Duration>[];
        final second = _Result(
          queue.generate(
            request: () async {
              starts.add(clock.elapsed);
              return 'next';
            },
            isCurrent: () => true,
            interval: () => Duration.zero,
            onProgress: (_) {},
          ),
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 6));
        expect(calls, 1);
        clock.elapse(const Duration(seconds: 1));
        expect(calls, 2);
        expect(first.error, isA<AiRateLimitFailure>());
        expect(second.done, isFalse);
        clock.elapse(const Duration(seconds: 7));
        expect(starts, [const Duration(seconds: 14)]);
        expect(second.value, 'next');
      });
    },
  );

  test('non-429 generation errors never retry', () {
    fakeAsync((clock) {
      final queue = _scheduler(clock);
      var calls = 0;
      final result = _Result(
        queue.generate(
          request: () async {
            calls++;
            throw const ApiFailure('network failure');
          },
          isCurrent: () => true,
          interval: () => Duration.zero,
          maxRetries: () => 10,
          onProgress: (_) {},
        ),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(calls, 1);
      expect(result.error, isA<ApiFailure>());
    });
  });

  test('invalid queued work is canceled without calling provider', () {
    fakeAsync((clock) {
      final queue = _scheduler(clock);
      final reply = Completer<String>();
      final first = _Result(
        queue.generate(
          request: () => reply.future,
          isCurrent: () => true,
          interval: () => Duration.zero,
          onProgress: (_) {},
        ),
      );
      var valid = true, called = false;
      final second = _Result(
        queue.generate(
          request: () async {
            called = true;
            return 'invalid';
          },
          isCurrent: () => valid,
          interval: () => Duration.zero,
          onProgress: (_) {},
        ),
      );
      valid = false;
      clock.elapse(const Duration(milliseconds: 300));
      expect(second.error, isA<AiGenerationCanceled>());
      reply.complete('first');
      clock.flushMicrotasks();
      expect(first.value, 'first');
      expect(called, isFalse);
    });
  });

  test(
    'canceling during backoff releases the next job after shared cooldown',
    () {
      fakeAsync((clock) {
        final queue = _scheduler(clock);
        var valid = true, requests = 0;
        final first = _Result(
          queue.generate(
            request: () async {
              requests++;
              throw const AiRateLimitFailure('limited');
            },
            isCurrent: () => valid,
            interval: () => Duration.zero,
            maxRetries: () => 10,
            onProgress: (_) {},
          ),
        );
        final starts = <Duration>[];
        final next = _Result(
          queue.generate(
            request: () async {
              starts.add(clock.elapsed);
              return 'next';
            },
            isCurrent: () => true,
            interval: () => Duration.zero,
            onProgress: (_) {},
          ),
        );
        clock.flushMicrotasks();
        valid = false;
        clock.elapse(const Duration(milliseconds: 300));
        expect(first.error, isA<AiGenerationCanceled>());
        expect(next.done, isFalse);
        clock.elapse(const Duration(milliseconds: 4700));
        expect(requests, 1);
        expect(starts, [const Duration(seconds: 5)]);
        expect(next.value, 'next');
        expect(clock.periodicTimerCount, 0);
      });
    },
  );

  test(
    'canceling a running request waits for tracked transport settlement before next HTTP',
    () {
      fakeAsync((clock) {
        final queue = _scheduler(clock);
        var valid = true, tokenCanceled = false, laterStarted = false;
        final transport = Completer<String>();
        final first = _Result(
          queue.generate(
            request: () {
              final token = AiRequestScheduler.currentCancellationToken!;
              token.whenCancel.then((_) => tokenCanceled = true);
              return AiRequestScheduler.trackTransport(transport.future);
            },
            isCurrent: () => valid,
            interval: () => Duration.zero,
            onProgress: (_) {},
          ),
        );
        final next = _Result(
          queue.generate(
            request: () async {
              laterStarted = true;
              return 'next';
            },
            isCurrent: () => true,
            interval: () => Duration.zero,
            onProgress: (_) {},
          ),
        );
        clock.flushMicrotasks();
        valid = false;
        clock.elapse(const Duration(milliseconds: 300));
        expect(first.error, isA<AiGenerationCanceled>());
        expect(tokenCanceled, isTrue);
        expect(laterStarted, isFalse);
        transport.completeError(
          DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.cancel,
          ),
        );
        clock.flushMicrotasks();
        expect(next.value, 'next');
        expect(laterStarted, isTrue);
      });
    },
  );
}
