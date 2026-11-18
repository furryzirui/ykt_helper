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
