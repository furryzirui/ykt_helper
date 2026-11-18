import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/background_runtime.dart';

class _MemoryStore implements KeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Startup extends AppAutostart {
  final suspensions = <bool>[];
  @override
  bool get supported => true;
  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {}
  @override
  Future<void> setSuspended(bool suspended) async => suspensions.add(suspended);
}

class _Runtime extends BackgroundRuntime {
  bool active = false;
  int exits = 0;
  Future<void>? stopBarrier;
  final requests = <bool>[];
  final userInitiatedRequests = <bool>[];
  final configurations = <({BackgroundServiceMode mode, DateTime? deadline})>[];
  void Function(BackgroundRuntimeState)? listener;
  BackgroundRuntimeState? restoredState;
  @override
  bool get supported => true;
  @override
  bool get enabled => active;
  @override
  bool get busy => false;
  @override
  void setStateListener(void Function(BackgroundRuntimeState)? listener) =>
      this.listener = listener;
  @override
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async => configurations.add((mode: mode, deadline: deadline));
  @override
  Future<BackgroundRuntimeState?> status() async => restoredState;
  @override
  Future<bool> setEnabled(bool enabled) async {
    requests.add(enabled);
    userInitiatedRequests.add(userInitiated);
    active = enabled;
    if (!enabled) await stopBarrier;
    return true;
  }

  @override
  Future<void> exitApplication() async => exits++;
}

const _lesson = Lesson(
  id: 'lesson',
  courseId: 'course',
  classroomId: 'classroom',
  title: '课堂',
  live: true,
);
const _question = Question(
  id: 'question',
  body: '题目',
  type: 1,
  options: {'A': '甲', 'B': '乙', 'C': '丙'},
);

class _Api extends RainApi {
  int checkins = 0, submissions = 0;
  List<Lesson> live = [];
  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<List<Lesson>> liveLessons() async => live;
  @override
  Future<ClassroomSession> checkin(String lessonId) async {
    checkins++;
    return ClassroomSession(
      userId: 'user',
      lessonId: lessonId,
      bearer: 'bearer',
      lessonToken: 'token',
    );
  }

  @override
  Future<AttendanceStatus> attendance(Lesson lesson) async =>
      AttendanceStatus.signed;
  @override
  Future<Presentation> presentation(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
    bool withAnswers = true,
  }) async => const Presentation(
    id: 'deck',
    title: '课件',
    slides: [Slide(id: 'slide', index: 0, imageUrl: '', question: _question)],
  );
  @override
  Future<Map<String, AnswerRecord>> ownAnswers(
    String lessonId,
    String presentationId,
  ) async => {};
  @override
  Future<void> submit(
    ClassroomSession session,
    Question question,
    dynamic answer,
  ) async => submissions++;
}

class _Harness {
  final store = _MemoryStore();
  final runtime = _Runtime();
  final startup = _Startup();
  final api = _Api();
  late final AppController controller;
  _Harness(FakeAsync async, {AppSettings? settings}) {
    final clock = async.getClock(DateTime(2026, 11, 18, 10));
    controller =
        AppController(
            api: api,
            store: store,
            background: runtime,
            autostart: startup,
            now: clock.now,
            startTimers: false,
            connectSockets: false,
          )
          ..account = const Account(id: 'user', name: '测试')
          ..settings = settings ?? AppSettings(autoEnter: true);
  }
  void dispose(FakeAsync async) {
    controller.dispose();
    async.flushMicrotasks();
  }
}

T _settle<T>(FakeAsync async, Future<T> future) {
  late T result;
  Object? error;
  var completed = false;
  future.then(
    (value) {
      result = value;
      completed = true;
    },
    onError: (Object e) {
      error = e;
      completed = true;
    },
  );
  async.flushMicrotasks();
  expect(
    completed,
    isTrue,
    reason: 'All fake operations should settle in microtasks',
  );
  if (error != null) throw error!;
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('timeout defaults to never and old settings retain that default', () {
    expect(AppSettings().serviceTimeoutMinutes, 0);
    expect(AppSettings.fromJson({}).serviceTimeoutMinutes, 0);
    expect(AppSettings().backgroundMode, BackgroundServiceMode.silentAudio);
  });

  for (final minutes in [0, 10, 120, 1440]) {
    test(
      'timeout $minutes minutes is persisted without starting a service',
      () {
        fakeAsync((async) {
          final h = _Harness(async);
          _settle(async, h.controller.setServiceTimeout(minutes));
          expect(h.controller.settings.serviceTimeoutMinutes, minutes);
          expect(
            AppSettings.fromJson(
              object(jsonDecode(h.store.values['settings']!)),
            ).serviceTimeoutMinutes,
            minutes,
          );
          expect(h.controller.serviceDeadline, isNull);
          expect(h.runtime.active, isFalse);
          h.dispose(async);
        });
      },
    );
  }

  test('invalid timeout does not overwrite persisted settings', () {
    fakeAsync((async) {
      final h = _Harness(async);
      expect(
        () => _settle(async, h.controller.setServiceTimeout(60)),
        throwsA(isA<ApiFailure>()),
      );
      expect(h.store.values, isEmpty);
      expect(h.controller.settings.serviceTimeoutMinutes, 0);
      h.dispose(async);
    });
  });

  test(
    'manual start begins countdown; retry does not extend it; reselection resets it',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        _settle(async, h.controller.setSystemService(true));
        final first = h.controller.serviceDeadline;
        expect(first, DateTime(2026, 11, 18, 10, 10));
        expect(h.controller.serviceRemaining, const Duration(minutes: 10));
        async.elapse(const Duration(minutes: 2));
        _settle(async, h.controller.retryBackground());
        _settle(async, h.controller.retryBackground());
        expect(h.controller.serviceDeadline, first);
        expect(h.controller.serviceRemaining, const Duration(minutes: 8));
        _settle(async, h.controller.setServiceTimeout(10));
        expect(h.controller.serviceDeadline, DateTime(2026, 11, 18, 10, 12));
        expect(h.controller.serviceRemaining, const Duration(minutes: 10));
        _settle(async, h.controller.setServiceTimeout(0));
        expect(h.controller.serviceDeadline, isNull);
        expect(h.controller.serviceRemaining, isNull);
        expect(h.runtime.active, isTrue);
        async.elapse(const Duration(days: 2));
        expect(h.runtime.active, isTrue);
        h.dispose(async);
      });
    },
  );

  test(
    'foreground expiry stops Android service and suppresses automatic restart',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(
            autoEnter: true,
            autoStartService: true,
            serviceTimeoutMinutes: 10,
          ),
        );
        _settle(async, h.controller.setSystemService(true));
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(h.runtime.active, isFalse);
        expect(h.startup.suspensions.last, isTrue);
        expect(h.runtime.exits, 0);
        final starts = h.runtime.requests.where((enabled) => enabled).length;
        _settle(async, h.controller.retryBackground());
        _settle(
          async,
          h.controller.saveSettings(
            AppSettings.fromJson(h.controller.settings.toJson()),
          ),
        );
        expect(h.runtime.requests.where((enabled) => enabled).length, starts);
        expect(h.controller.serviceRemaining, Duration.zero);
        h.api.live = [_lesson];
        _settle(async, h.controller.refresh());
        expect(
          h.api.checkins,
          1,
          reason:
              'Foreground automation remains available after service expiry',
        );
        _settle(async, h.controller.setSystemService(true));
        expect(h.runtime.active, isTrue);
        expect(h.controller.serviceRemaining, const Duration(minutes: 10));
        h.dispose(async);
      });
    },
  );

  test(
    'background expiry requests Android exit after stopping the service',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        _settle(async, h.controller.setSystemService(true));
        h.controller.setForeground(false);
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(h.runtime.active, isFalse);
        expect(h.runtime.exits, 1);
        h.dispose(async);
      });
    },
  );

  for (final foreground in [true, false]) {
    test(
      'Windows expiry ${foreground ? 'keeps foreground app' : 'exits background app'}',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        fakeAsync((async) {
          final h = _Harness(async);
          _settle(async, h.controller.setServiceTimeout(10));
          h.controller.setForeground(foreground);
          async.elapse(const Duration(minutes: 10));
          async.flushMicrotasks();
          expect(h.runtime.exits, foreground ? 0 : 1);
          if (foreground) {
            h.controller.setForeground(false);
            async.flushMicrotasks();
            expect(
              h.runtime.exits,
              0,
              reason:
                  'A foreground expiry must not exit retroactively after hiding',
            );
          }
          h.dispose(async);
        });
      },
    );
  }

  test('Windows returning to foreground during expiry prevents exit', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    fakeAsync((async) {
      final h = _Harness(async);
      _settle(async, h.controller.setServiceTimeout(10));
      h.controller.setForeground(false);
      final stopped = Completer<void>();
      h.runtime.stopBarrier = stopped.future;
      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(h.runtime.requests.last, isFalse);
      expect(h.runtime.exits, 0);
      h.controller.setForeground(true);
      stopped.complete();
      async.flushMicrotasks();
      expect(h.runtime.exits, 0);
      expect(h.controller.serviceRemaining, Duration.zero);
      h.controller.setForeground(false);
      async.flushMicrotasks();
      expect(h.runtime.exits, 0);
      h.dispose(async);
    });
  });

  test(
    'native monotonic expiry stops service even if wall deadline is still in the future',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(
            autoEnter: true,
            autoStartService: true,
            serviceTimeoutMinutes: 10,
          ),
        );
        _settle(async, h.controller.setSystemService(true));
        final deadline = h.controller.serviceDeadline;
        h.runtime.active = false;
        h.runtime.listener!(
          BackgroundRuntimeState(
            enabled: false,
            deadline: deadline,
            reason: 'deadline',
          ),
        );
        async.flushMicrotasks();
        expect(h.runtime.active, isFalse);
        expect(h.controller.serviceRemaining, Duration.zero);
        expect(
          object(jsonDecode(h.store.values['serviceSession']!))['expired'],
          isTrue,
        );
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isFalse);
        h.dispose(async);
      });
    },
  );

  test(
    'iOS requires mode consent, reuses it for autostart, and requires consent for a new mode',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, autoStartService: true),
        );
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isFalse);
        expect(h.controller.backgroundWarning, contains('确认'));
        expect(
          () => _settle(async, h.controller.setSystemService(true)),
          throwsA(isA<ApiFailure>()),
        );
        _settle(async, h.controller.setSystemService(true, iosConfirmed: true));
        expect(h.runtime.active, isTrue);
        expect(h.controller.settings.iosBackgroundConsentMode, 'silentAudio');
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isTrue);
        final fresh = _Harness(
          async,
          settings: AppSettings.fromJson(h.controller.settings.toJson()),
        );
        _settle(async, fresh.controller.retryBackground());
        expect(
          fresh.runtime.active,
          isTrue,
          reason: 'Same-mode saved consent permits automatic service startup',
        );
        fresh.dispose(async);
        final changed = AppSettings.fromJson(h.controller.settings.toJson())
          ..backgroundMode = BackgroundServiceMode.pictureInPicture;
        _settle(async, h.controller.saveSettings(changed));
        expect(h.runtime.active, isFalse);
        _settle(async, h.controller.setSystemService(true, iosConfirmed: true));
        expect(h.runtime.active, isTrue);
        expect(
          h.controller.settings.iosBackgroundConsentMode,
          'pictureInPicture',
        );
        h.dispose(async);
      });
    },
  );

  test('iOS continued task rejects an unlimited session', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fakeAsync((async) {
      final h = _Harness(
        async,
        settings: AppSettings(
          autoEnter: true,
          backgroundMode: BackgroundServiceMode.continuedTask,
          serviceTimeoutMinutes: 10,
        ),
      );
      expect(
        () => _settle(async, h.controller.setServiceTimeout(0)),
        throwsA(isA<ApiFailure>()),
      );
      expect(h.controller.settings.serviceTimeoutMinutes, 10);
      expect(h.store.values, isEmpty);
      h.controller.settings.serviceTimeoutMinutes = 0;
      expect(
        () => _settle(
          async,
          h.controller.setSystemService(true, iosConfirmed: true),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(h.runtime.requests.where((enabled) => enabled), isEmpty);
      expect(h.controller.serviceDeadline, isNull);
      h.dispose(async);
    });
  });

  test('iOS continued task always saves automatic startup as disabled', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fakeAsync((async) {
      final h = _Harness(async);
      _settle(
        async,
        h.controller.saveSettings(
          AppSettings(
            autoEnter: true,
            autoStartService: true,
            appAutoStart: true,
            backgroundMode: BackgroundServiceMode.continuedTask,
            iosBackgroundConsentMode: 'continuedTask',
            serviceTimeoutMinutes: 120,
          ),
        ),
      );
      expect(h.controller.settings.autoStartService, isFalse);
      expect(h.controller.settings.appAutoStart, isFalse);
      final persisted = AppSettings.fromJson(
        object(jsonDecode(h.store.values['settings']!)),
      );
      expect(persisted.autoStartService, isFalse);
      expect(persisted.appAutoStart, isFalse);
      expect(h.runtime.requests.where((enabled) => enabled), isEmpty);
      h.dispose(async);
    });
  });

  test('saved iOS continued-task consent never starts a fresh session', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fakeAsync((async) {
      final h = _Harness(
        async,
        settings: AppSettings(
          autoEnter: true,
          autoStartService: true,
          backgroundMode: BackgroundServiceMode.continuedTask,
          iosBackgroundConsentMode: 'continuedTask',
          serviceTimeoutMinutes: 120,
        ),
      );
      _settle(async, h.controller.retryBackground());
      _settle(async, h.controller.refresh());
      expect(h.runtime.active, isFalse);
      expect(h.runtime.requests.where((enabled) => enabled), isEmpty);
      expect(h.runtime.userInitiatedRequests, everyElement(isFalse));
      expect(h.controller.serviceDeadline, isNull);
      h.dispose(async);
    });
  });

  test(
    'iOS continued task forwards one explicit start and refresh never reissues user intent',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(
            autoEnter: true,
            backgroundMode: BackgroundServiceMode.continuedTask,
            serviceTimeoutMinutes: 120,
          ),
        );
        _settle(async, h.controller.setSystemService(true, iosConfirmed: true));
        expect(h.runtime.active, isTrue);
        expect(h.runtime.userInitiatedRequests, [true]);
        expect(h.runtime.userInitiated, isFalse);
        final deadline = h.controller.serviceDeadline;
        _settle(async, h.controller.refresh());
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isTrue);
        expect(
          h.runtime.userInitiatedRequests.where((requested) => requested),
          hasLength(1),
        );
        expect(h.runtime.userInitiated, isFalse);
        expect(h.controller.serviceDeadline, deadline);
        h.runtime.active = false;
        h.runtime.listener!(
          const BackgroundRuntimeState(enabled: false, reason: 'systemExpired'),
        );
        async.flushMicrotasks();
        final starts = h.runtime.requests.where((enabled) => enabled).length;
        _settle(async, h.controller.refresh());
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.requests.where((enabled) => enabled).length, starts);
        expect(h.runtime.active, isFalse);
        h.dispose(async);
      });
    },
  );

  test(
    'iOS background expiry stops resources without requesting process exit',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        _settle(async, h.controller.setSystemService(true, iosConfirmed: true));
        h.controller.setForeground(false);
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(h.runtime.active, isFalse);
        expect(h.runtime.exits, 0);
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isFalse);
        h.dispose(async);
      });
    },
  );

  test(
    'background without a service cannot auto-enter or fill incoming answers',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, autoAnswer: true),
        );
        h.api.live = [_lesson];
        h.controller.setForeground(false);
        _settle(async, h.controller.refresh());
        expect(h.api.checkins, 0);
        h.controller.setForeground(true);
        final live = _settle(async, h.controller.enter(_lesson));
        _settle(
          async,
          h.controller.processEvent(live, {
            'op': 'hello',
            'presentation': 'deck',
          }),
        );
        _settle(async, h.controller.syncAnswers(live));
        h.controller.setForeground(false);
        _settle(
          async,
          h.controller.processEvent(live, {
            'op': 'unlockproblem',
            'problem': {
              'prob': 'question',
              'pres': 'deck',
              'dt': DateTime.now().millisecondsSinceEpoch,
              'limit': -1,
            },
          }),
        );
        expect(live.draftAnswers, isEmpty);
        expect(h.api.submissions, 0);
        h.dispose(async);
      });
    },
  );

  test(
    'moving to background without a service cancels already queued submission',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoAnswer: true, autoSubmit: true),
        );
        final live = _settle(async, h.controller.enter(_lesson));
        _settle(
          async,
          h.controller.processEvent(live, {
            'op': 'hello',
            'presentation': 'deck',
          }),
        );
        _settle(async, h.controller.syncAnswers(live));
        _settle(
          async,
          h.controller.processEvent(live, {
            'op': 'unlockproblem',
            'problem': {
              'prob': 'question',
              'pres': 'deck',
              'dt': DateTime.now().millisecondsSinceEpoch,
              'limit': -1,
            },
          }),
        );
        expect(live.draftAnswers['question'], ['A']);
        expect(live.autoStates['question'], contains('30 秒'));
        h.controller.setForeground(false);
        async.elapse(const Duration(seconds: 35));
        async.flushMicrotasks();
        expect(h.api.submissions, 0);
        h.dispose(async);
      });
    },
  );
}
