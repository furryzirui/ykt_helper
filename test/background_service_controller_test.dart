import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/app_logs.dart';
import 'package:ykt_helper/services/background_runtime.dart';

class _MemoryStore implements KeyValueStore {
  final values = <String, String>{};
  String? blockedKey;
  Completer<void>? writeBarrier;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key == blockedKey) await writeBarrier?.future;
    values[key] = value;
  }

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

class _Logs extends AppLogs {
  @override
  Future<void> initialize() async {}
}

class _NoDirectories extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async =>
      throw UnsupportedError('No legacy diagnostics directory in this fixture');
}

class _Runtime extends BackgroundRuntime {
  bool active = false;
  int exits = 0;
  Future<void>? stopBarrier;
  final requests = <bool>[];
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
  Future<BackgroundRuntimeState?> status() async {
    if (restoredState != null) active = restoredState!.enabled;
    return restoredState;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    requests.add(enabled);
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
            logs: _Logs(),
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
  late PathProviderPlatform directories;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    directories = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoDirectories();
  });
  tearDown(() {
    PathProviderPlatform.instance = directories;
    debugDefaultTargetPlatformOverride = null;
  });

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
    'manual start resets timeout; only a current-session selection starts a countdown',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        _settle(async, h.controller.setSystemService(true));
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
        expect(h.controller.serviceDeadline, isNull);
        _settle(async, h.controller.setServiceTimeout(10));
        final first = h.controller.serviceDeadline;
        expect(first, DateTime(2026, 11, 18, 10, 10));
        expect(h.controller.serviceRemaining, const Duration(minutes: 10));
        async.elapse(const Duration(minutes: 2));
        _settle(async, h.controller.retryBackground());
        _settle(async, h.controller.retryBackground());
        _settle(async, h.controller.refresh());
        _settle(async, h.controller.setSystemService(true));
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
    'automatic startup and finite timeout are mutually exclusive on every platform',
    () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: AppSettings(autoEnter: true, autoStartService: true),
          );
          _settle(
            async,
            h.controller.setSystemService(true, iosConfirmed: true),
          );
          for (final minutes in [10, 120, 1440]) {
            expect(
              () => _settle(async, h.controller.setServiceTimeout(minutes)),
              throwsA(
                isA<ApiFailure>().having(
                  (failure) => failure.message,
                  'reason',
                  contains('先关闭自动启动服务'),
                ),
              ),
            );
          }
          expect(h.controller.settings.serviceTimeoutMinutes, 0);
          expect(h.controller.serviceDeadline, isNull);
          _settle(async, h.controller.setServiceTimeout(0));
          expect(h.runtime.active, isTrue);
          h.dispose(async);
        });
      }
    },
  );

  test(
    'enabling automatic startup clears Dart and native deadlines immediately',
    () {
      fakeAsync((async) {
        final h = _Harness(async);
        _settle(async, h.controller.setSystemService(true));
        _settle(async, h.controller.setServiceTimeout(10));
        expect(h.runtime.configurations.last.deadline, isNotNull);
        async.elapse(const Duration(minutes: 2));
        _settle(
          async,
          h.controller.saveSettings(
            AppSettings.fromJson(h.controller.settings.toJson())
              ..autoStartService = true,
          ),
        );
        expect(h.controller.settings.autoStartService, isTrue);
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
        expect(h.controller.serviceDeadline, isNull);
        expect(h.runtime.configurations.last.deadline, isNull);
        expect(
          object(
            jsonDecode(h.store.values['settings']!),
          )['serviceTimeoutMinutes'],
          0,
        );
        expect(object(jsonDecode(h.store.values['serviceSession']!)), {
          'deadlineEpochMs': null,
          'expired': false,
        });
        async.elapse(const Duration(hours: 24));
        async.flushMicrotasks();
        expect(h.runtime.active, isTrue);
        expect(h.runtime.exits, 0);
        h.dispose(async);
      });
    },
  );

  test(
    'disabling automatic startup allows a current-session finite timeout',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, autoStartService: true),
        );
        _settle(async, h.controller.setSystemService(true));
        _settle(
          async,
          h.controller.saveSettings(
            AppSettings.fromJson(h.controller.settings.toJson())
              ..autoStartService = false,
          ),
        );
        _settle(async, h.controller.setServiceTimeout(10));
        expect(h.controller.serviceRemaining, const Duration(minutes: 10));
        async.elapse(const Duration(minutes: 2));
        _settle(async, h.controller.retryBackground());
        expect(h.controller.serviceRemaining, const Duration(minutes: 8));
        h.dispose(async);
      });
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '${platform.name} restores legacy conflicting startup settings as unlimited',
      () {
        debugDefaultTargetPlatformOverride = platform;
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: AppSettings(
              autoEnter: true,
              autoStartService: true,
              serviceTimeoutMinutes: 120,
              iosBackgroundConsentMode: 'silentAudio',
            ),
          );
          h.store.values['settings'] = jsonEncode(
            h.controller.settings.toJson(),
          );
          h.runtime.restoredState = BackgroundRuntimeState(
            enabled: true,
            deadline: DateTime(2026, 11, 18, 12),
          );
          _settle(async, h.controller.initialize());
          expect(h.controller.error, isNull);
          expect(h.controller.settings.autoStartService, isTrue);
          expect(h.controller.settings.serviceTimeoutMinutes, 0);
          expect(h.controller.serviceDeadline, isNull);
          expect(h.runtime.configurations, isNotEmpty);
          expect(
            h.runtime.configurations.every((value) => value.deadline == null),
            isTrue,
          );
          expect(
            object(
              jsonDecode(h.store.values['settings']!),
            )['serviceTimeoutMinutes'],
            0,
          );
          async.elapse(const Duration(hours: 3));
          async.flushMicrotasks();
          expect(h.runtime.active, isTrue);
          h.dispose(async);
        });
      },
    );
  }

  test(
    'automatic startup rejects manual service shutdown without changing any state',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, autoStartService: true),
        );
        _settle(async, h.controller.setSystemService(true));
        final stored = Map<String, String>.of(h.store.values);
        final requests = List<bool>.of(h.runtime.requests);
        final suspensions = List<bool>.of(h.startup.suspensions);
        expect(
          () => _settle(async, h.controller.setSystemService(false)),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.message,
              'reason',
              '请先关闭自动启动服务，再关闭系统服务',
            ),
          ),
        );
        expect(h.runtime.active, isTrue);
        expect(h.runtime.requests, requests);
        expect(h.startup.suspensions, suspensions);
        expect(h.store.values, stored);
        expect(h.controller.settings.autoStartService, isTrue);
        expect(h.controller.serviceDeadline, isNull);
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isTrue);
        _settle(
          async,
          h.controller.saveSettings(
            AppSettings.fromJson(h.controller.settings.toJson())
              ..autoStartService = false,
          ),
        );
        _settle(async, h.controller.setSystemService(false));
        expect(h.runtime.active, isFalse);
        h.dispose(async);
      });
    },
  );

  test(
    'a stale native deadline during automatic-start persistence cannot stop the new unlimited session',
    () {
      fakeAsync((async) {
        final h = _Harness(async);
        _settle(async, h.controller.setSystemService(true));
        _settle(async, h.controller.setServiceTimeout(10));
        final oldDeadline = h.controller.serviceDeadline;
        final stopRequests = h.runtime.requests.where((value) => !value).length;
        h.store.blockedKey = 'serviceSession';
        final barrier = Completer<void>();
        h.store.writeBarrier = barrier;
        var completed = false;
        Object? failure;
        h.controller
            .saveSettings(
              AppSettings.fromJson(h.controller.settings.toJson())
                ..autoStartService = true,
            )
            .then(
              (_) => completed = true,
              onError: (Object error) {
                failure = error;
                completed = true;
              },
            );
        async.flushMicrotasks();
        expect(completed, isFalse);
        expect(h.controller.settings.autoStartService, isTrue);
        expect(h.controller.serviceDeadline, isNull);
        expect(h.runtime.configurations.last.deadline, oldDeadline);
        h.runtime.active = false;
        h.runtime.listener!(
          BackgroundRuntimeState(
            enabled: false,
            deadline: oldDeadline,
            reason: 'deadline',
          ),
        );
        async.flushMicrotasks();
        expect(
          h.runtime.requests.where((value) => !value).length,
          stopRequests,
        );
        expect(h.startup.suspensions.last, isFalse);
        expect(h.controller.serviceDeadline, isNull);
        barrier.complete();
        h.store.writeBarrier = null;
        h.store.blockedKey = null;
        async.flushMicrotasks();
        expect(completed, isTrue);
        expect(failure, isNull);
        expect(h.runtime.active, isTrue);
        expect(h.runtime.configurations.last.deadline, isNull);
        expect(h.controller.serviceDeadline, isNull);
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
        expect(h.controller.backgroundWarning, isNull);
        expect(
          h.runtime.requests.where((value) => !value).length,
          stopRequests,
        );
        async.elapse(const Duration(minutes: 11));
        async.flushMicrotasks();
        expect(h.runtime.active, isTrue);
        expect(h.runtime.exits, 0);
        h.dispose(async);
      });
    },
  );

  test(
    'automatic starts discard the saved timeout and running refreshes preserve a selected timer',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(
            autoEnter: true,
            autoStartService: true,
            serviceTimeoutMinutes: 120,
          ),
        );
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isTrue);
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
        expect(h.controller.serviceDeadline, isNull);
        expect(
          object(
            jsonDecode(h.store.values['settings']!),
          )['serviceTimeoutMinutes'],
          0,
        );
        _settle(
          async,
          h.controller.saveSettings(
            AppSettings.fromJson(h.controller.settings.toJson())
              ..autoStartService = false,
          ),
        );
        _settle(async, h.controller.setSystemService(true));
        _settle(async, h.controller.setServiceTimeout(10));
        final deadline = h.controller.serviceDeadline;
        async.elapse(const Duration(minutes: 2));
        _settle(async, h.controller.refresh());
        _settle(async, h.controller.retryBackground());
        expect(h.controller.serviceDeadline, deadline);
        expect(h.controller.serviceRemaining, const Duration(minutes: 8));
        _settle(async, h.controller.setSystemService(false));
        _settle(async, h.controller.retryBackground());
        expect(h.runtime.active, isFalse);
        _settle(async, h.controller.setSystemService(true));
        expect(h.runtime.active, isTrue);
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
        expect(h.controller.serviceDeadline, isNull);
        h.dispose(async);
      });
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '${platform.name} reattaches a running native countdown unchanged',
      () {
        debugDefaultTargetPlatformOverride = platform;
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: AppSettings(
              autoEnter: true,
              serviceTimeoutMinutes: 10,
              iosBackgroundConsentMode: 'silentAudio',
            ),
          );
          final deadline = DateTime(2026, 11, 18, 10, 8);
          h.store.values['settings'] = jsonEncode(
            h.controller.settings.toJson(),
          );
          h.store.values['serviceSession'] = jsonEncode({
            'deadlineEpochMs': DateTime(2026, 11, 18, 9).millisecondsSinceEpoch,
            'expired': true,
          });
          h.runtime.restoredState = BackgroundRuntimeState(
            enabled: true,
            deadline: deadline,
          );
          _settle(async, h.controller.initialize());
          expect(h.controller.error, isNull);
          expect(h.runtime.active, isTrue);
          expect(h.controller.serviceDeadline, deadline);
          expect(h.controller.serviceRemaining, const Duration(minutes: 8));
          expect(h.controller.settings.serviceTimeoutMinutes, 10);
          _settle(async, h.controller.retryBackground());
          expect(h.controller.serviceDeadline, deadline);
          h.dispose(async);
        });
      },
    );

    test(
      '${platform.name} new process starts without an old expired countdown',
      () {
        debugDefaultTargetPlatformOverride = platform;
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: AppSettings(
              autoEnter: true,
              autoStartService: true,
              serviceTimeoutMinutes: 120,
              iosBackgroundConsentMode: 'silentAudio',
            ),
          );
          h.store.values['settings'] = jsonEncode(
            h.controller.settings.toJson(),
          );
          h.store.values['serviceSession'] = jsonEncode({
            'deadlineEpochMs': DateTime(2026, 11, 18, 9).millisecondsSinceEpoch,
            'expired': true,
          });
          h.runtime.restoredState = const BackgroundRuntimeState(
            enabled: false,
          );
          _settle(async, h.controller.initialize());
          expect(h.controller.error, isNull);
          expect(h.runtime.active, isTrue);
          expect(h.controller.serviceDeadline, isNull);
          expect(h.controller.settings.serviceTimeoutMinutes, 0);
          expect(object(jsonDecode(h.store.values['serviceSession']!)), {
            'deadlineEpochMs': null,
            'expired': false,
          });
          h.dispose(async);
        });
      },
    );
  }

  test('native service recreation clears a surviving Flutter countdown', () {
    fakeAsync((async) {
      final h = _Harness(async);
      _settle(async, h.controller.setSystemService(true));
      _settle(async, h.controller.setServiceTimeout(10));
      async.elapse(const Duration(minutes: 2));
      h.runtime.listener!(const BackgroundRuntimeState(enabled: true));
      async.flushMicrotasks();
      expect(h.controller.serviceDeadline, isNull);
      expect(h.controller.settings.serviceTimeoutMinutes, 0);
      expect(object(jsonDecode(h.store.values['serviceSession']!)), {
        'deadlineEpochMs': null,
        'expired': false,
      });
      async.elapse(const Duration(hours: 2));
      async.flushMicrotasks();
      expect(h.runtime.active, isTrue);
      h.dispose(async);
    });
  });

  test(
    'unknown native status preserves stored timeout without arming or starting',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        h.store.values['settings'] = jsonEncode(h.controller.settings.toJson());
        final storedSession = jsonEncode({
          'deadlineEpochMs': DateTime(
            2026,
            11,
            18,
            10,
            8,
          ).millisecondsSinceEpoch,
          'expired': false,
        });
        h.store.values['serviceSession'] = storedSession;
        final storedSettings = h.store.values['settings'];
        _settle(async, h.controller.initialize());
        expect(h.controller.settings.serviceTimeoutMinutes, 10);
        expect(h.controller.serviceDeadline, isNull);
        expect(h.controller.backgroundWarning, contains('无法确认'));
        expect(h.store.values['settings'], storedSettings);
        expect(h.store.values['serviceSession'], storedSession);
        expect(h.runtime.requests, isEmpty);
        async.elapse(const Duration(hours: 1));
        async.flushMicrotasks();
        expect(h.runtime.exits, 0);
        expect(h.runtime.requests, isEmpty);
        h.dispose(async);
      });
    },
  );

  for (final running in [true, false]) {
    test(
      'automatic recovery from unknown status remains unlimited (${running ? 'running' : 'stopped'})',
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
          h.store.values['settings'] = jsonEncode(
            h.controller.settings.toJson(),
          );
          _settle(async, h.controller.initialize());
          final deadline = DateTime(2026, 11, 18, 10, 8);
          h.runtime.restoredState = BackgroundRuntimeState(
            enabled: running,
            deadline: running ? deadline : null,
          );
          _settle(async, h.controller.retryBackground());
          expect(h.runtime.active, isTrue);
          expect(h.controller.backgroundWarning, isNull);
          expect(h.controller.serviceDeadline, isNull);
          expect(h.controller.settings.serviceTimeoutMinutes, 0);
          h.dispose(async);
        });
      },
    );
  }

  test(
    'manual start first stops an unknown session before replacing its timer',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        h.store.values['settings'] = jsonEncode(h.controller.settings.toJson());
        _settle(async, h.controller.initialize());
        expect(h.runtime.requests, isEmpty);
        _settle(async, h.controller.setSystemService(true));
        expect(h.runtime.requests, [false, true]);
        expect(h.controller.serviceDeadline, isNull);
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
        expect(h.runtime.active, isTrue);
        h.dispose(async);
      });
    },
  );

  test('Windows fresh launches reset a saved countdown to never', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    fakeAsync((async) {
      final h = _Harness(
        async,
        settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 120),
      );
      h.store.values['settings'] = jsonEncode(h.controller.settings.toJson());
      h.store.values['serviceSession'] = jsonEncode({
        'deadlineEpochMs': DateTime(2026, 11, 18, 11).millisecondsSinceEpoch,
        'expired': false,
      });
      _settle(async, h.controller.initialize());
      expect(h.controller.error, isNull);
      expect(h.controller.settings.serviceTimeoutMinutes, 0);
      expect(h.controller.serviceDeadline, isNull);
      _settle(async, h.controller.setServiceTimeout(10));
      final deadline = h.controller.serviceDeadline;
      _settle(async, h.controller.retryBackground());
      expect(h.controller.serviceDeadline, deadline);
      expect(h.controller.serviceRemaining, const Duration(minutes: 10));
      h.dispose(async);
    });
  });

  test(
    'foreground expiry stops Android service and suppresses automatic restart',
    () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        _settle(async, h.controller.setSystemService(true));
        _settle(async, h.controller.setServiceTimeout(10));
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
        expect(h.controller.serviceRemaining, isNull);
        expect(h.controller.settings.serviceTimeoutMinutes, 0);
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
        _settle(async, h.controller.setServiceTimeout(10));
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
          settings: AppSettings(autoEnter: true, serviceTimeoutMinutes: 10),
        );
        _settle(async, h.controller.setSystemService(true));
        _settle(async, h.controller.setServiceTimeout(10));
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
        _settle(async, h.controller.setServiceTimeout(10));
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
