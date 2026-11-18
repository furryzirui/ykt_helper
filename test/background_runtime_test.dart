import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/background_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const permissions = MethodChannel('ykt_helper/app_permissions');
  final calls = <MethodCall>[];
  late BackgroundRuntime runtime;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    runtime = BackgroundRuntime();
    calls.clear();
    messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (call) async {
      calls.add(call);
      return call.method == 'status'
          ? {'enabled': false, 'mode': 'silentAudio', 'deadlineEpochMs': null}
          : true;
    });
    messenger.setMockMethodCallHandler(
      permissions,
      (_) async => {
        'camera': 'denied',
        'photos': 'notRequired',
        'notifications': 'denied',
        'battery': 'unsupported',
        'autostart': 'unsupported',
        'location': 'granted',
      },
    );
  });
  tearDown(() {
    runtime.setStateListener(null);
    messenger.setMockMethodCallHandler(BackgroundRuntime.channel, null);
    messenger.setMockMethodCallHandler(permissions, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final mode in [
    BackgroundServiceMode.silentAudio,
    BackgroundServiceMode.pictureInPicture,
    BackgroundServiceMode.location,
    BackgroundServiceMode.native,
  ]) {
    test(
      'iOS ${mode.name} start and stop carry the same absolute deadline',
      () async {
        final deadline = DateTime.now().add(const Duration(minutes: 10));
        await runtime.configure(mode: mode, deadline: deadline);
        expect(await runtime.setEnabled(true), isTrue);
        expect(runtime.enabled, isTrue);
        expect(await runtime.setEnabled(false), isTrue);
        expect(runtime.enabled, isFalse);
        expect(calls.map((call) => call.method), [
          'configure',
          'setEnabled',
          'setEnabled',
        ]);
        for (final call in calls) {
          expect((call.arguments as Map)['mode'], mode.name);
          expect(
            (call.arguments as Map)['deadlineEpochMs'],
            deadline.millisecondsSinceEpoch,
          );
        }
      },
    );
  }

  test(
    'iOS continued task sends user initiation only for the explicit start',
    () async {
      final deadline = DateTime.now().add(const Duration(hours: 2));
      await runtime.configure(
        mode: BackgroundServiceMode.continuedTask,
        deadline: deadline,
      );
      runtime.userInitiated = true;
      expect(await runtime.setEnabled(true), isTrue);
      runtime.userInitiated = false;
      expect(await runtime.setEnabled(true), isTrue);
      expect(await runtime.setEnabled(false), isTrue);
      final enableCalls = calls
          .where((call) => call.method == 'setEnabled')
          .toList();
      expect(enableCalls, hasLength(3));
      expect((enableCalls.first.arguments as Map)['userInitiated'], isTrue);
      for (final call in enableCalls) {
        expect((call.arguments as Map)['mode'], 'continuedTask');
        expect(
          (call.arguments as Map)['deadlineEpochMs'],
          deadline.millisecondsSinceEpoch,
        );
      }
      expect(
        enableCalls
            .skip(1)
            .every(
              (call) => !(call.arguments as Map).containsKey('userInitiated'),
            ),
        isTrue,
      );
    },
  );

  test(
    'Android only uses native mode even when a saved iOS mode is selected',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
        permissions,
        (_) async => {
          'camera': 'denied',
          'photos': 'notRequired',
          'notifications': 'granted',
          'battery': 'granted',
          'autostart': 'needsConfirmation',
        },
      );
      await runtime.configure(mode: BackgroundServiceMode.pictureInPicture);
      expect(await runtime.setEnabled(true), isTrue);
      expect(
        calls.every((call) => (call.arguments as Map)['mode'] == 'native'),
        isTrue,
      );
    },
  );

  test('expired deadline is never sent as an enable request', () async {
    await runtime.configure(
      mode: BackgroundServiceMode.silentAudio,
      deadline: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(await runtime.setEnabled(true), isFalse);
    expect(runtime.enabled, isFalse);
    expect(runtime.failureReason, 'deadline');
    expect(
      calls
          .where((call) => call.method == 'setEnabled')
          .map((call) => (call.arguments as Map)['enabled']),
      [false],
    );
  });

  test(
    'iOS location mode cannot start without actual Always authorization',
    () async {
      messenger.setMockMethodCallHandler(
        permissions,
        (_) async => {
          'camera': 'denied',
          'photos': 'notRequired',
          'notifications': 'denied',
          'battery': 'unsupported',
          'autostart': 'unsupported',
          'location': 'needsConfirmation',
        },
      );
      await runtime.configure(mode: BackgroundServiceMode.location);
      expect(await runtime.setEnabled(true), isFalse);
      expect(runtime.failureReason, 'locationPermission');
      expect(calls.where((call) => call.method == 'setEnabled'), isEmpty);
    },
  );

  test('native start failure is not reported as an active service', () async {
    messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (call) async {
      calls.add(call);
      return call.method == 'setEnabled' &&
              (call.arguments as Map)['enabled'] == true
          ? false
          : true;
    });
    await runtime.configure(mode: BackgroundServiceMode.pictureInPicture);
    expect(await runtime.setEnabled(true), isFalse);
    expect(runtime.enabled, isFalse);
  });

  test(
    'status adopts real native expiry and state listener reports later stops',
    () async {
      final deadline = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );
      messenger.setMockMethodCallHandler(
        BackgroundRuntime.channel,
        (call) async => {
          'enabled': false,
          'mode': 'silentAudio',
          'deadlineEpochMs': deadline.millisecondsSinceEpoch,
          'reason': 'deadline',
        },
      );
      final status = await runtime.status();
      expect(status!.enabled, isFalse);
      expect(status.deadline, deadline);
      expect(status.reason, 'deadline');
      final events = <BackgroundRuntimeState>[];
      runtime.setStateListener(events.add);
      await messenger.handlePlatformMessage(
        BackgroundRuntime.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('stateChanged', {
            'enabled': false,
            'mode': 'silentAudio',
            'deadlineEpochMs': null,
            'reason': 'startFailed',
          }),
        ),
        (_) {},
      );
      expect(events, hasLength(1));
      expect(events.single.reason, 'startFailed');
      expect(runtime.enabled, isFalse);
      expect(runtime.failureReason, 'startFailed');
    },
  );

  test('missing native status remains unknown rather than enabled', () async {
    messenger.setMockMethodCallHandler(
      BackgroundRuntime.channel,
      (_) async => null,
    );
    expect(await runtime.status(), isNull);
    expect(runtime.enabled, isFalse);
  });

  test(
    'diagnostics reads only allowlisted state and does not adopt service state',
    () async {
      messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (
        call,
      ) async {
        calls.add(call);
        return {
          'enabled': true,
          'mode': 'silentAudio',
          'appState': 'background',
          'audioPlaying': true,
          'audioTimeMs': 750,
          'pipActive': false,
          'pipFrameCount': 12,
          'cookie': 'secret',
          'location': 'private',
        };
      });
      final snapshot = await runtime.diagnostics();
      expect(snapshot!.toJson(), {
        'enabled': true,
        'mode': 'silentAudio',
        'appState': 'background',
        'audioPlaying': true,
        'audioTimeMs': 750,
        'pipActive': false,
        'pipFrameCount': 12,
      });
      expect(calls.single.method, 'diagnostics');
      expect(runtime.enabled, false);
      expect(runtime.failureReason, isNull);
    },
  );

  test(
    'invalid diagnostic snapshots or native errors remain unavailable without leaking text',
    () async {
      for (final response in [
        null,
        true,
        {'enabled': 'true', 'mode': 'silentAudio', 'appState': 'background'},
        {'enabled': true, 'mode': 'secret-cookie', 'appState': 'background'},
        {'enabled': true, 'mode': 'silentAudio', 'appState': 'secret-key'},
      ]) {
        messenger.setMockMethodCallHandler(
          BackgroundRuntime.channel,
          (_) async => response,
        );
        expect(await runtime.diagnostics(), isNull);
      }
      messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (_) async {
        throw PlatformException(code: 'private', message: 'private-token');
      });
      expect(await runtime.diagnostics(), isNull);
      expect(runtime.failureMessage, isNull);
    },
  );

  testWidgets(
    'new diagnostic samples neither overlap nor reuse a timed-out native snapshot',
    (tester) async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final native = Completer<Map<String, Object?>>();
      var requests = 0;
      messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (
        call,
      ) async {
        requests++;
        return native.future;
      });
      final first = runtime.diagnostics();
      final second = runtime.diagnostics();
      await tester.pump();
      expect(requests, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(await first, isNull);
      expect(await second, isNull);
      final later = runtime.diagnostics();
      await tester.pump();
      expect(requests, 1);
      native.complete({
        'enabled': true,
        'mode': 'silentAudio',
        'appState': 'background',
      });
      await tester.pump();
      expect(await later, isNull);
      final fresh = runtime.diagnostics();
      await tester.pump();
      expect(requests, 2);
      expect((await fresh)!.enabled, true);
      expect(runtime.enabled, false);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test(
      '${platform.name} does not request iOS diagnostic snapshots',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        expect(await runtime.diagnostics(), isNull);
        expect(calls, isEmpty);
      },
    );
  }

  test(
    'native start exception reads failure before cleanup and preserves its message',
    () async {
      var stopped = false;
      messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'setEnabled') {
          if ((call.arguments as Map)['enabled'] == true) {
            throw PlatformException(
              code: 'unavailable',
              message: 'fallback message',
            );
          }
          stopped = true;
          return true;
        }
        if (call.method == 'status') {
          return {
            'enabled': false,
            'reason': stopped ? 'stopped' : 'pipUnavailable',
            if (!stopped) 'message': '设备不支持画中画',
          };
        }
        return true;
      });
      await runtime.configure(mode: BackgroundServiceMode.pictureInPicture);
      expect(await runtime.setEnabled(true), false);
      expect(calls.map((call) => call.method), [
        'configure',
        'setEnabled',
        'status',
        'setEnabled',
      ]);
      expect(stopped, true);
      expect(runtime.failureReason, 'pipUnavailable');
      expect(runtime.failureMessage, '设备不支持画中画');
      expect(runtime.enabled, false);
    },
  );

  test(
    'native false start reads detailed failure and remains disabled',
    () async {
      messenger.setMockMethodCallHandler(BackgroundRuntime.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'setEnabled') return false;
        if (call.method == 'status') {
          return {
            'enabled': false,
            'reason': 'audioFailed',
            'message': '音频会话不可用',
          };
        }
        return true;
      });
      await runtime.configure(mode: BackgroundServiceMode.silentAudio);
      expect(await runtime.setEnabled(true), false);
      expect(runtime.failureReason, 'audioFailed');
      expect(runtime.failureMessage, '音频会话不可用');
      expect(runtime.enabled, false);
      expect(calls.map((call) => call.method), [
        'configure',
        'setEnabled',
        'status',
      ]);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test(
      '${platform.name} exit accepts a visibility veto and rejects invalid responses',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        messenger.setMockMethodCallHandler(
          BackgroundRuntime.channel,
          (_) async => false,
        );
        await runtime.exitApplication();
        messenger.setMockMethodCallHandler(
          BackgroundRuntime.channel,
          (_) async => null,
        );
        await expectLater(
          runtime.exitApplication(),
          throwsA(isA<ApiFailure>()),
        );
        messenger.setMockMethodCallHandler(
          BackgroundRuntime.channel,
          (_) async => true,
        );
        await runtime.exitApplication();
      },
    );
  }

  test('iOS never calls process exit', () async {
    await runtime.exitApplication();
    expect(calls, isEmpty);
  });
}
