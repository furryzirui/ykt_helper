import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/app_logs.dart';
import 'package:ykt_helper/services/background_diagnostics.dart';
import 'package:ykt_helper/services/background_runtime.dart';

class _Store implements KeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Api extends RainApi {
  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<List<Lesson>> liveLessons() async => [];
}

class _Startup extends AppAutostart {
  @override
  bool get supported => false;
  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {}
  @override
  Future<void> setSuspended(bool suspended) async {}
}

class _Runtime extends BackgroundRuntime {
  bool active = false;
  int diagnosticCalls = 0;
  BackgroundServiceMode mode = BackgroundServiceMode.silentAudio;
  Completer<IosBackgroundSnapshot?>? pending;
  void Function(BackgroundRuntimeState)? listener;
  @override
  bool get supported => true;
  @override
  bool get enabled => active;
  @override
  bool get busy => false;
  @override
  void setStateListener(void Function(BackgroundRuntimeState)? value) =>
      listener = value;
  @override
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {
    this.mode = mode;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    active = enabled;
    return true;
  }

  @override
  Future<BackgroundRuntimeState?> status() async => null;
  @override
  Future<IosBackgroundSnapshot?> diagnostics() {
    diagnosticCalls++;
    return pending?.future ?? Future.value(snapshot());
  }

  IosBackgroundSnapshot snapshot() => IosBackgroundSnapshot.parse({
    'enabled': active,
    'mode': mode.name,
    'appState': 'background',
    'audioPlaying': mode == BackgroundServiceMode.silentAudio,
    'audioTimeMs': 1250,
    'pipActive': mode == BackgroundServiceMode.pictureInPicture,
    'pipFrameCount': 12,
  })!;

  void nativeStop() {
    active = false;
    listener?.call(
      const BackgroundRuntimeState(enabled: false, reason: 'systemExpired'),
    );
  }
}

class _Harness {
  final runtime = _Runtime();
  final store = _Store();
  final api = _Api();
  final startup = _Startup();
  late final AppController controller;
  bool disposed = false;

  _Harness(
    FakeAsync async, {
    bool? diagnostics = true,
    int timeoutMinutes = 0,
  }) {
    final clock = async.getClock(DateTime(2026, 11, 18, 10));
    // The null branch deliberately exercises both real constructor defaults.
    controller = diagnostics == null
        ? AppController(
            api: api,
            store: store,
            background: runtime,
            autostart: startup,
            now: clock.now,
            startTimers: false,
            connectSockets: false,
          )
        : AppController(
            api: api,
            store: store,
            background: runtime,
            autostart: startup,
            now: clock.now,
            startTimers: false,
            connectSockets: false,
            iosBackgroundDiagnostics: diagnostics,
          );
    controller
      ..account = const Account(id: 'user', name: '测试')
      ..settings = AppSettings(
        autoEnter: true,
        serviceTimeoutMinutes: timeoutMinutes,
      );
  }

  List<AppLogEntry> get heartbeats => controller.logs.entries
      .where((entry) => entry.event == AppLogEvent.backgroundHeartbeat)
      .toList();
  List<AppLogEntry> get snapshots => controller.logs.entries
      .where((entry) => entry.event == AppLogEvent.backgroundSnapshot)
      .toList();

  void start(FakeAsync async) =>
      _settle(async, controller.setSystemService(true, iosConfirmed: true));

  void dispose(FakeAsync async) {
    if (!disposed) {
      disposed = true;
      controller.dispose();
      async.flushMicrotasks();
    }
  }
}

void _settle(FakeAsync async, Future<void> operation) {
  var completed = false;
  Object? error;
  operation.then(
    (_) => completed = true,
    onError: (Object failure) {
      error = failure;
      completed = true;
    },
  );
  async.flushMicrotasks();
  expect(completed, isTrue);
  if (error != null) throw error!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('ordinary builds do not schedule iOS background diagnostics', () {
    fakeAsync((async) {
      final h = _Harness(async, diagnostics: null);
      expect(h.controller.iosBackgroundDiagnostics, isFalse);
      expect(h.controller.logs.iosBackgroundDiagnostics, isFalse);
      h.start(async);
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(h.runtime.diagnosticCalls, 0);
      expect(h.heartbeats, isEmpty);
      expect(h.snapshots, isEmpty);
      h.dispose(async);
    });
  });

  test('iOS records one heartbeat and snapshot per real ten-second sample', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.start(async);
      expect(h.controller.logs.iosBackgroundDiagnostics, isTrue);
      async.elapse(const Duration(seconds: 9));
      expect(h.runtime.diagnosticCalls, 0);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(h.runtime.diagnosticCalls, 1);
      expect(h.heartbeats, hasLength(1));
      expect(h.snapshots, hasLength(1));
      expect(h.heartbeats.single.foreground, isTrue);
      expect(h.snapshots.single.success, isTrue);
      expect(
        h.snapshots.single.backgroundSnapshot!.mode,
        BackgroundServiceMode.silentAudio,
      );
      h.controller.setForeground(false);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(h.runtime.diagnosticCalls, 2);
      expect(h.heartbeats, hasLength(2));
      expect(h.heartbeats.first.foreground, isFalse);
      expect(h.snapshots, hasLength(2));
      h.dispose(async);
    });
  });

  test(
    'resumption after a blocked interval never fabricates missed samples',
    () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.start(async);
        async.elapseBlocking(const Duration(minutes: 2));
        expect(h.runtime.diagnosticCalls, 0);
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(h.runtime.diagnosticCalls, 1);
        expect(h.heartbeats, hasLength(1));
        expect(h.snapshots, hasLength(1));
        async.elapse(const Duration(seconds: 9));
        expect(h.runtime.diagnosticCalls, 1);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(h.runtime.diagnosticCalls, 2);
        h.dispose(async);
      });
    },
  );

  test('refresh and retry cannot overlap an in-flight native snapshot', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.runtime.pending = Completer<IosBackgroundSnapshot?>();
      h.start(async);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(h.runtime.diagnosticCalls, 1);
      _settle(async, h.controller.retryBackground());
      _settle(async, h.controller.refresh());
      async.elapse(const Duration(seconds: 2));
      expect(h.runtime.diagnosticCalls, 1);
      expect(h.heartbeats, hasLength(1));
      expect(h.snapshots, isEmpty);
      h.runtime.pending!.complete(h.runtime.snapshot());
      h.runtime.pending = null;
      async.flushMicrotasks();
      expect(h.snapshots, hasLength(1));
      async.elapse(const Duration(seconds: 9));
      expect(h.runtime.diagnosticCalls, 1);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(h.runtime.diagnosticCalls, 2);
      h.dispose(async);
    });
  });

  test(
    'snapshot timeout is diagnostic only and late results are not recorded',
    () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.runtime.pending = Completer<IosBackgroundSnapshot?>();
        h.start(async);
        async.elapse(const Duration(seconds: 13));
        async.flushMicrotasks();
        expect(h.runtime.active, isTrue);
        expect(h.controller.backgroundWarning, isNull);
        expect(h.snapshots, hasLength(1));
        expect(h.snapshots.single.success, isFalse);
        expect(h.snapshots.single.backgroundSnapshot, isNull);
        h.runtime.pending!.complete(h.runtime.snapshot());
        h.runtime.pending = null;
        async.flushMicrotasks();
        expect(h.snapshots, hasLength(1));
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(h.runtime.diagnosticCalls, 2);
        expect(h.snapshots.first.success, isTrue);
        h.dispose(async);
      });
    },
  );

  for (final stop in ['manual', 'native', 'dispose']) {
    test(
      '$stop stop cancels future sampling and discards an in-flight reply',
      () {
        fakeAsync((async) {
          final h = _Harness(async);
          h.runtime.pending = Completer<IosBackgroundSnapshot?>();
          h.start(async);
          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();
          expect(h.runtime.diagnosticCalls, 1);
          switch (stop) {
            case 'manual':
              _settle(async, h.controller.setSystemService(false));
            case 'native':
              h.runtime.nativeStop();
              async.flushMicrotasks();
            case 'dispose':
              h.dispose(async);
          }
          h.runtime.pending!.complete(h.runtime.snapshot());
          h.runtime.pending = null;
          async.flushMicrotasks();
          expect(h.snapshots, isEmpty);
          async.elapse(const Duration(minutes: 1));
          async.flushMicrotasks();
          expect(h.runtime.diagnosticCalls, 1);
          expect(h.heartbeats, hasLength(1));
          expect(h.snapshots, isEmpty);
          h.dispose(async);
        });
      },
    );
  }

  test(
    'service deadline ends diagnostics without post-expiry observations',
    () {
      fakeAsync((async) {
        final h = _Harness(async, timeoutMinutes: 10);
        h.start(async);
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(h.runtime.active, isFalse);
        expect(h.controller.serviceRemaining, Duration.zero);
        final callsAtExpiry = h.runtime.diagnosticCalls;
        final beatsAtExpiry = h.heartbeats.length;
        final snapshotsAtExpiry = h.snapshots.length;
        expect(callsAtExpiry, greaterThan(0));
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(h.runtime.diagnosticCalls, callsAtExpiry);
        expect(h.heartbeats.length, beatsAtExpiry);
        expect(h.snapshots.length, snapshotsAtExpiry);
        h.dispose(async);
      });
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test('${platform.name} ignores an enabled iOS diagnostic flag', () {
      debugDefaultTargetPlatformOverride = platform;
      fakeAsync((async) {
        final h = _Harness(async);
        h.start(async);
        expect(h.runtime.active, isTrue);
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(h.runtime.diagnosticCalls, 0);
        expect(h.heartbeats, isEmpty);
        expect(h.snapshots, isEmpty);
        h.dispose(async);
      });
    });
  }
}
