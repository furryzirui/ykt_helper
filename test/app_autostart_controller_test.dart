import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/app_logs.dart';
import 'package:ykt_helper/services/background_runtime.dart';

class _Store implements KeyValueStore {
  final values = <String, String>{};
  final settingsWrites = <Json>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    if (key == 'settings') settingsWrites.add(object(jsonDecode(value)));
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Autostart extends AppAutostart {
  final bool available;
  final registrations = <({bool enabled, bool eligible})>[];
  final suspensions = <bool>[];
  int failuresRemaining = 0;
  String permission = 'granted';
  Object? permissionError;
  int permissionChecks = 0;
  Future<void> Function(bool enabled, bool eligible)? beforeConfigure;
  ({bool enabled, bool eligible})? savedRegistration;

  _Autostart({this.available = true});

  @override
  bool get supported => available;

  @override
  Future<String> permissionStatus() async {
    permissionChecks++;
    if (permissionError != null) throw permissionError!;
    return permission;
  }

  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {
    if (!available) return;
    registrations.add((enabled: enabled, eligible: eligible));
    await beforeConfigure?.call(enabled, eligible);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const ApiFailure('测试：系统注册失败');
    }
    savedRegistration = (enabled: enabled, eligible: eligible);
  }

  @override
  Future<void> setSuspended(bool suspended) async {
    if (available) suspensions.add(suspended);
  }
}

class _Background extends BackgroundRuntime {
  @override
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {}
  @override
  Future<BackgroundRuntimeState?> status() async =>
      BackgroundRuntimeState(enabled: active);

  final bool available;
  final requests = <bool>[];
  bool active = false;
  bool fail = false;

  _Background({this.available = true});

  @override
  bool get supported => available;

  @override
  bool get enabled => active;

  @override
  bool get busy => false;

  @override
  Future<bool> setEnabled(bool enabled) async {
    requests.add(enabled);
    if (fail && enabled) throw const ApiFailure('测试：后台服务启动失败');
    active = enabled;
    return true;
  }
}

class _Logs extends AppLogs {
  @override
  Future<void> initialize() async {}
}

class _Api extends RainApi {
  int profileCalls = 0, courseCalls = 0, lessonCalls = 0, logoutCalls = 0;
  final restoredCookies = <String>[];
  final profileReplies = <FutureOr<Account> Function()>[];
  static const user = Account(id: 'restored', name: '恢复账号');

  @override
  Future<Account> profile() async {
    profileCalls++;
    return profileReplies.isEmpty ? user : await profileReplies.removeAt(0)();
  }

  @override
  Future<void> restoreCookies(String serialized) async {
    restoredCookies.add(serialized);
  }

  @override
  Future<List<Course>> courses() async {
    courseCalls++;
    return [];
  }

  @override
  Future<List<Lesson>> liveLessons() async {
    lessonCalls++;
    return [];
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  late _Autostart autostart;
  late _Background background;
  late _Api api;
  late AppController controller;

  AppController create({
    bool backgroundAvailable = true,
    bool startupAvailable = true,
  }) {
    store = _Store();
    autostart = _Autostart(available: startupAvailable);
    background = _Background(available: backgroundAvailable);
    api = _Api();
    return AppController(
      store: store,
      autostart: autostart,
      background: background,
      api: api,
      logs: _Logs(),
      startTimers: false,
      connectSockets: false,
    );
  }

  void savedSession() {
    store.values['cookies'] = '[{"test":"restored-session"}]';
    store.values['settings'] = jsonEncode(
      AppSettings(
        autoEnter: true,
        autoStartService: true,
        appAutoStart: true,
      ).toJson(),
    );
  }

  Future<void> expectSavedAndReloaded(AppSettings expected) async {
    expect(controller.settings.toJson(), expected.toJson());
    expect(object(jsonDecode(store.values['settings']!)), expected.toJson());
    final restored = AppController(
      store: store,
      autostart: autostart,
      background: background,
      api: api,
      logs: _Logs(),
      startTimers: false,
      connectSockets: false,
    );
    try {
      await restored.initialize();
      expect(restored.settings.toJson(), expected.toJson());
    } finally {
      restored.dispose();
    }
  }

  setUp(() => controller = create());
  tearDown(() {
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Windows refuses only explicit denial before persistence or registration',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      controller.dispose();
      controller = create(backgroundAvailable: false)..account = _Api.user;
      final previous = controller.settings;
      autostart.permission = 'denied';
      await expectLater(
        controller.saveSettings(
          AppSettings(autoEnter: true, appAutoStart: true),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(store.settingsWrites, isEmpty);
      expect(autostart.registrations, isEmpty);
      expect(identical(controller.settings, previous), true);
    },
  );

  test(
    'Windows permits unknown approval and read failures after native preparation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      controller.dispose();
      controller = create(backgroundAvailable: false)..account = _Api.user;
      for (final status in ['needsConfirmation', 'unsupported']) {
        autostart.permission = status;
        await controller.saveSettings(
          AppSettings(autoEnter: true, appAutoStart: true),
        );
        expect(controller.settings.appAutoStart, true);
        expect(autostart.registrations.last, (enabled: true, eligible: true));
      }
      autostart.permissionError = const ApiFailure('无法读取自启动状态');
      await controller.saveSettings(
        AppSettings(autoEnter: true, appAutoStart: true),
      );
      expect(controller.settings.appAutoStart, true);
      expect(autostart.registrations.last, (enabled: true, eligible: true));
    },
  );

  test(
    'Windows can turn off old preference after permission revocation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      controller.dispose();
      controller = create(backgroundAvailable: false)..account = _Api.user;
      controller.settings = AppSettings(autoEnter: true, appAutoStart: true);
      autostart.permission = 'denied';
      await controller.saveSettings(
        AppSettings(autoEnter: true, appAutoStart: false),
      );
      expect(controller.settings.appAutoStart, false);
      expect(autostart.permissionChecks, 0);
      expect(autostart.registrations.last.enabled, false);
    },
  );

  test(
    'Windows revoked startup permission does not block stopping answer automation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      controller.dispose();
      controller = create(backgroundAvailable: false)..account = _Api.user;
      controller.settings = AppSettings(
        autoEnter: true,
        autoAnswer: true,
        appAutoStart: true,
      );
      autostart.permission = 'denied';
      await controller.saveSettings(
        AppSettings(autoEnter: true, autoAnswer: false, appAutoStart: true),
      );
      expect(controller.settings.autoAnswer, false);
      expect(controller.settings.autoEnter, true);
      expect(controller.settings.appAutoStart, true);
      expect(autostart.registrations.last, (enabled: true, eligible: false));
      expect(
        object(jsonDecode(store.values['settings']!))['autoAnswer'],
        false,
      );
    },
  );

  test(
    'Android OEM confirmation does not block enabling its configured preference',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      controller.account = _Api.user;
      autostart.permission = 'needsConfirmation';
      await controller.saveSettings(
        AppSettings(
          autoEnter: true,
          autoStartService: true,
          appAutoStart: true,
        ),
      );
      expect(controller.settings.appAutoStart, true);
      expect(autostart.permissionChecks, 0);
    },
  );

  test(
    'Android app startup depends on automation and service auto-start',
    () async {
      controller.account = _Api.user;
      await controller.saveSettings(
        AppSettings(autoAnswer: true, appAutoStart: true),
      );
      expect(controller.settings.appAutoStart, false);
      expect(autostart.registrations.last.enabled, false);

      await controller.saveSettings(
        AppSettings(
          autoAnswer: true,
          autoStartService: true,
          appAutoStart: true,
        ),
      );
      expect(controller.settings.appAutoStart, true);
      expect(autostart.registrations.last, (enabled: true, eligible: true));
      expect(background.active, true);

      await controller.saveSettings(
        AppSettings(autoStartService: true, appAutoStart: true),
      );
      expect(controller.settings.autoStartService, false);
      expect(controller.settings.appAutoStart, false);
      expect(autostart.registrations.last, (enabled: false, eligible: false));
      expect(background.active, false);
    },
  );

  test(
    'Windows app startup does not require an Android system service',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      controller.dispose();
      controller = create(backgroundAvailable: false)..account = _Api.user;
      await controller.saveSettings(
        AppSettings(autoEnter: true, appAutoStart: true),
      );
      expect(controller.settings.appAutoStart, true);
      expect(autostart.registrations.last, (enabled: true, eligible: true));
      expect(background.active, false);
    },
  );

  test(
    'unsupported app startup is normalized off before persistence',
    () async {
      controller.dispose();
      controller = create(backgroundAvailable: false, startupAvailable: false);
      await controller.saveSettings(
        AppSettings(autoAnswer: true, appAutoStart: true),
      );
      expect(controller.settings.appAutoStart, false);
      expect(
        object(jsonDecode(store.values['settings']!))['appAutoStart'],
        false,
      );
      expect(autostart.registrations, isEmpty);
    },
  );

  test(
    'fixed automation saves and reloads missing fixed answer categories',
    () async {
      for (final absent in ['single', 'multiple', 'judgment', 'subjective']) {
        final requested = AppSettings(
          autoAnswer: true,
          fixedSingleAnswer: absent == 'single' ? '' : 'A',
          fixedMultipleAnswer: absent == 'multiple' ? ' ' : 'AB',
          fixedJudgmentAnswer: absent == 'judgment' ? '' : 'A',
          fixedSubjectiveAnswer: absent == 'subjective' ? '\n' : '不会',
        );
        await controller.saveSettings(requested);
        await expectSavedAndReloaded(requested);
      }
    },
  );

  test(
    'AI automation saves and reloads empty connection fields and prompts',
    () async {
      for (final absent in ['baseUrl', 'apiKey', 'model', 'prompt', 'all']) {
        final requested = AppSettings(
          autoAnswer: true,
          answerMode: AnswerMode.ai,
          baseUrl: ['baseUrl', 'all'].contains(absent)
              ? ''
              : 'https://offline.invalid/v1',
          apiKey: ['apiKey', 'all'].contains(absent) ? '' : 'offline-only',
          model: ['model', 'all'].contains(absent) ? '' : 'test-model',
          customPrompt: ['prompt', 'all'].contains(absent)
              ? ''
              : defaultAiPrompt,
        );
        await controller.saveSettings(requested);
        await expectSavedAndReloaded(requested);
      }
      final whitespacePrompt = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'not an endpoint',
        customPrompt: '  \n',
      );
      await controller.saveSettings(whitespacePrompt);
      await expectSavedAndReloaded(whitespacePrompt);
    },
  );

  test(
    'fixed choice settings persist invalid selections without changing them',
    () async {
      for (final invalid in [
        AppSettings(autoAnswer: true, fixedSingleAnswer: 'AB'),
        AppSettings(autoAnswer: true, fixedSingleAnswer: 'E'),
        AppSettings(autoAnswer: true, fixedMultipleAnswer: 'AA'),
        AppSettings(autoAnswer: true, fixedMultipleAnswer: 'AE'),
        AppSettings(autoAnswer: true, fixedJudgmentAnswer: 'C'),
      ]) {
        await controller.saveSettings(invalid);
        await expectSavedAndReloaded(invalid);
      }
      await controller.saveSettings(
        AppSettings(
          autoAnswer: true,
          fixedSingleAnswer: 'D',
          fixedMultipleAnswer: 'ACD',
          fixedJudgmentAnswer: 'B',
        ),
      );
      expect(controller.settings.fixedSingleAnswer, 'D');
      expect(controller.settings.fixedMultipleAnswer, 'ACD');
      expect(controller.settings.fixedJudgmentAnswer, 'B');
    },
  );

  test(
    'submission delays outside validation bounds remain durable after restart',
    () async {
      for (final delay in [-1, 0, 3601]) {
        final requested = AppSettings(
          autoAnswer: true,
          autoSubmit: true,
          autoSubmitDelaySeconds: delay,
        );
        await controller.saveSettings(requested);
        await expectSavedAndReloaded(requested);
      }
    },
  );

  test(
    'OS registration failure preserves saved settings and reports independently',
    () async {
      final previous = AppSettings(autoEnter: true, fixedSingleAnswer: 'B');
      controller.settings = previous;
      store.values['settings'] = jsonEncode(previous.toJson());
      controller.account = _Api.user;
      autostart.failuresRemaining = 1;
      final requested = AppSettings(
        autoAnswer: true,
        autoStartService: true,
        appAutoStart: true,
      );
      await controller.saveSettings(requested);
      expect(controller.settings.toJson(), requested.toJson());
      expect(object(jsonDecode(store.values['settings']!)), requested.toJson());
      expect(store.settingsWrites.length, 1);
      expect(autostart.registrations, [(enabled: true, eligible: true)]);
      expect(background.active, true);
      expect(controller.backgroundWarning, contains('应用自启动设置失败'));
      await controller.retryBackground();
      expect(controller.backgroundWarning, isNull);
      expect(autostart.savedRegistration, (enabled: true, eligible: true));
    },
  );

  test(
    'background runtime failure cannot reject a durable setting save',
    () async {
      controller.account = _Api.user;
      background.fail = true;
      final requested = AppSettings(autoEnter: true, autoStartService: true);
      await controller.saveSettings(requested);
      expect(controller.settings.toJson(), requested.toJson());
      expect(object(jsonDecode(store.values['settings']!)), requested.toJson());
      expect(controller.backgroundWarning, contains('后台运行未开启'));
    },
  );

  test(
    'manual off suspends native recovery and wins until explicit service on',
    () async {
      controller.account = _Api.user;
      controller.settings = AppSettings(
        autoAnswer: true,
        autoStartService: true,
        appAutoStart: true,
      );
      await controller.retryBackground();
      expect(background.active, true);
      await controller.setSystemService(false);
      expect(autostart.suspensions, [true]);
      expect(background.active, false);
      expect(autostart.registrations.last, (enabled: true, eligible: false));
      await controller.retryBackground();
      await controller.saveSettings(
        AppSettings(
          autoEnter: true,
          autoStartService: true,
          appAutoStart: true,
        ),
      );
      expect(background.active, false);
      expect(autostart.registrations.last.eligible, false);
      await controller.setSystemService(true);
      expect(autostart.suspensions, [true, false]);
      expect(background.active, true);
      expect(autostart.registrations.last.eligible, true);
    },
  );

  test(
    'concurrent saves keep the latest durable settings when OS registration fails',
    () async {
      controller.account = _Api.user;
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var firstRegistration = true;
      var failSecond = true;
      autostart.beforeConfigure = (enabled, eligible) async {
        if (firstRegistration) {
          firstRegistration = false;
          firstStarted.complete();
          await releaseFirst.future;
        } else if (!enabled && eligible && failSecond) {
          failSecond = false;
          throw const ApiFailure('第二个保存注册失败');
        }
      };
      final firstSettings = AppSettings(
        autoAnswer: true,
        autoStartService: true,
        appAutoStart: true,
        fixedSingleAnswer: 'B',
      );
      final firstSave = controller.saveSettings(firstSettings);
      await firstStarted.future;
      final secondSave = controller.saveSettings(
        AppSettings(
          autoAnswer: true,
          autoStartService: true,
          appAutoStart: false,
          fixedSingleAnswer: 'C',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        store.settingsWrites.length,
        1,
        reason: 'A pending transaction owns both disk and OS registration',
      );
      releaseFirst.complete();
      await firstSave;
      await secondSave;
      expect(controller.settings.fixedSingleAnswer, 'C');
      expect(controller.settings.appAutoStart, false);
      expect(
        object(jsonDecode(store.values['settings']!)),
        controller.settings.toJson(),
      );
      expect(store.settingsWrites.length, 2);
      expect(autostart.savedRegistration, (enabled: true, eligible: true));
      expect(background.active, true);
      expect(controller.backgroundWarning, contains('应用自启动设置失败'));

      final lastSettings = AppSettings(fixedSingleAnswer: 'D');
      await controller.saveSettings(lastSettings);
      expect(controller.settings.toJson(), lastSettings.toJson());
      expect(
        object(jsonDecode(store.values['settings']!)),
        lastSettings.toJson(),
      );
      expect(autostart.savedRegistration, (enabled: false, eligible: false));
      expect(background.active, false);
    },
  );

  test('logout clears eligibility and stops the current runtime', () async {
    controller.account = _Api.user;
    controller.settings = AppSettings(
      autoEnter: true,
      autoStartService: true,
      appAutoStart: true,
    );
    store.values['cookies'] = 'saved';
    store.values['answers:${_Api.user.id}'] = '{}';
    await controller.retryBackground();
    await controller.logout();
    expect(controller.account, null);
    expect(autostart.registrations.last, (enabled: true, eligible: false));
    expect(background.active, false);
    expect(store.values.containsKey('cookies'), false);
    expect(store.values.containsKey('answers:${_Api.user.id}'), false);
    expect(api.logoutCalls, 1);
    await controller.retryBackground();
    expect(background.active, false);
  });

  test('native registration failure cannot prevent logout cleanup', () async {
    controller.account = _Api.user;
    controller.settings = AppSettings(
      autoEnter: true,
      autoStartService: true,
      appAutoStart: true,
    );
    store.values['cookies'] = 'saved';
    store.values['answers:${_Api.user.id}'] = '{}';
    await controller.retryBackground();
    expect(background.active, true);
    autostart.failuresRemaining = 1;
    try {
      await controller.logout();
    } on ApiFailure {
      // A platform failure may remain visible to the caller, but it must not
      // retain the session or leave a classroom service processing events.
    }
    expect(controller.account, null);
    expect(background.active, false);
    expect(store.values.containsKey('cookies'), false);
    expect(store.values.containsKey('answers:${_Api.user.id}'), false);
    expect(api.logoutCalls, 1);
  });

  test(
    'boot session waits for connectivity then resumes only after profile verification',
    () async {
      savedSession();
      api.profileReplies.add(() => throw const ApiFailure('offline'));
      await controller.initialize();
      expect(controller.initialized, true);
      expect(controller.account, null);
      expect(controller.error, 'offline');
      expect(api.restoredCookies.length, 1);
      expect(api.courseCalls, 0);
      expect(api.lessonCalls, 0);
      expect(
        background.active,
        true,
        reason: 'Keep the polling isolate alive while offline',
      );
      expect(autostart.registrations.last, (enabled: true, eligible: true));

      await controller.retryRestoredLogin();
      expect(controller.account?.id, _Api.user.id);
      expect(controller.error, null);
      expect(api.profileCalls, 2);
      expect(api.courseCalls, 1);
      expect(api.lessonCalls, 1);
      expect(controller.busy, false);
      expect(background.active, true);
      await controller.retryRestoredLogin();
      expect(api.profileCalls, 2);
    },
  );

  test(
    '401 on first profile disables restored-session retry and eligibility',
    () async {
      savedSession();
      api.profileReplies.add(() => throw const ApiFailure('expired', 401));
      await controller.initialize();
      await controller.retryRestoredLogin();
      expect(api.profileCalls, 1);
      expect(api.courseCalls, 0);
      expect(controller.account, null);
      expect(background.active, false);
      expect(autostart.registrations.last.eligible, false);
    },
  );

  test('401 after a transient profile failure stops further retries', () async {
    savedSession();
    api.profileReplies.addAll([
      () => throw const ApiFailure('offline'),
      () => throw const ApiFailure('expired', 401),
    ]);
    await controller.initialize();
    await controller.retryRestoredLogin();
    await controller.retryRestoredLogin();
    expect(api.profileCalls, 2);
    expect(controller.account, null);
    expect(background.active, false);
    expect(autostart.registrations.last.eligible, false);
  });

  test(
    'late restored profile after logout cannot reauthenticate or refresh',
    () async {
      savedSession();
      final pending = Completer<Account>();
      final started = Completer<void>();
      api.profileReplies.addAll([
        () => throw const ApiFailure('offline'),
        () {
          started.complete();
          return pending.future;
        },
      ]);
      await controller.initialize();
      final retry = controller.retryRestoredLogin();
      await started.future;
      expect(controller.busy, true);
      await controller.logout();
      pending.complete(_Api.user);
      await retry;
      expect(controller.account, null);
      expect(api.courseCalls, 0);
      expect(api.lessonCalls, 0);
      expect(background.active, false);
      expect(autostart.registrations.last.eligible, false);
      expect(
        controller.busy,
        false,
        reason: 'Logout must leave the UI usable after a late retry',
      );
    },
  );
  test(
    'late initial profile after logout cannot restore the old session',
    () async {
      savedSession();
      final pending = Completer<Account>();
      final started = Completer<void>();
      api.profileReplies.add(() {
        started.complete();
        return pending.future;
      });
      final initialization = controller.initialize();
      await started.future;
      await controller.logout();
      pending.complete(_Api.user);
      await initialization;
      expect(controller.account, null);
      expect(api.courseCalls, 0);
      expect(api.lessonCalls, 0);
      expect(background.active, false);
      expect(autostart.registrations.last.eligible, false);
      expect(store.values.containsKey('cookies'), false);
      expect(controller.busy, false);
    },
  );

  test(
    'late restored-profile failure after logout cannot set an old-session error',
    () async {
      savedSession();
      final pending = Completer<Account>();
      final started = Completer<void>();
      api.profileReplies.addAll([
        () => throw const ApiFailure('offline'),
        () {
          started.complete();
          return pending.future;
        },
      ]);
      await controller.initialize();
      final retry = controller.retryRestoredLogin();
      await started.future;
      await controller.logout();
      pending.completeError(const ApiFailure('old account expired', 401));
      await retry;
      expect(controller.account, null);
      expect(controller.error, null);
      expect(controller.busy, false);
      expect(background.active, false);
      expect(api.courseCalls, 0);
    },
  );

  test(
    'concurrent recovery requests share the single pending profile attempt',
    () async {
      savedSession();
      final pending = Completer<Account>();
      final started = Completer<void>();
      api.profileReplies.addAll([
        () => throw const ApiFailure('offline'),
        () {
          started.complete();
          return pending.future;
        },
      ]);
      await controller.initialize();
      final first = controller.retryRestoredLogin();
      await started.future;
      await controller.retryRestoredLogin();
      expect(api.profileCalls, 2);
      expect(api.courseCalls, 0);
      pending.complete(_Api.user);
      await first;
      expect(api.profileCalls, 2);
      expect(api.courseCalls, 1);
      expect(controller.account?.id, _Api.user.id);
    },
  );
}
