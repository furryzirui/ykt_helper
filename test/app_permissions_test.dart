import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_permissions.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/background_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissionChannel = MethodChannel('ykt_helper/app_permissions');
  const backgroundChannel = MethodChannel('ykt_helper/background_runtime');
  const legacyChannel = MethodChannel('ykt_helper/runtime_permissions');
  const permissions = AppPermissions();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var legacyPermissionCalls = 0;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    legacyPermissionCalls = 0;
    messenger.setMockMethodCallHandler(backgroundChannel, (call) async {
      calls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(legacyChannel, (_) async {
      legacyPermissionCalls++;
      return true;
    });
    messenger.setMockMethodCallHandler(
      AppAutostart.channel,
      (_) async => {
        'enabled': false,
        'suspended': false,
        'permission': 'denied',
      },
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    for (final channel in [
      permissionChannel,
      backgroundChannel,
      legacyChannel,
      AppAutostart.channel,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Map<String, String> state({
    String notifications = 'granted',
    String battery = 'granted',
  }) => {
    'camera': 'denied',
    'notifications': notifications,
    'photos': 'notRequired',
    'battery': battery,
    'autostart': 'needsConfirmation',
  };

  test(
    'check maps every native permission state without requesting authorization',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        methods.add(call.method);
        return state();
      });
      final result = await permissions.check();
      expect(result.map((item) => item.permission), AppPermission.values);
      expect(result.map((item) => item.status), [
        PermissionStatus.denied,
        PermissionStatus.granted,
        PermissionStatus.notRequired,
        PermissionStatus.granted,
        PermissionStatus.needsConfirmation,
        PermissionStatus.notRequired,
      ]);
      expect(methods, ['check']);
      expect(legacyPermissionCalls, 0);
    },
  );

  test(
    'missing or malformed native state fails instead of assuming granted',
    () async {
      for (final response in [
        null,
        {'camera': 'granted'},
        {...state(), 'battery': 'unknown'},
        {'camera': true},
      ]) {
        messenger.setMockMethodCallHandler(
          permissionChannel,
          (_) async => response,
        );
        await expectLater(permissions.check(), throwsA(isA<ApiFailure>()));
      }
    },
  );

  test('native state error is surfaced clearly', () async {
    messenger.setMockMethodCallHandler(permissionChannel, (_) async {
      throw PlatformException(
        code: 'permission_check_failed',
        message: '无法读取应用权限状态',
      );
    });
    await expectLater(
      permissions.check(),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.message,
          'message',
          contains('无法读取'),
        ),
      ),
    );
  });

  test(
    'openSettings sends only the selected permission and rejects unconfirmed navigation',
    () async {
      final selected = <String>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        expect(call.method, 'openSettings');
        selected.add((call.arguments as Map)['permission'] as String);
        return selected.length < 4;
      });
      for (final permission in [
        AppPermission.camera,
        AppPermission.notifications,
        AppPermission.photos,
      ]) {
        await permissions.openSettings(permission);
      }
      await expectLater(
        permissions.openSettings(AppPermission.battery),
        throwsA(isA<ApiFailure>()),
      );
      expect(selected, ['camera', 'notifications', 'photos', 'battery']);
    },
  );

  test(
    'other platforms report unsupported and never open Android settings',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(permissionChannel, (_) async {
        nativeCalls++;
        return state();
      });
      final result = await permissions.check();
      expect(
        result.every(
          (item) =>
              item.status ==
              (item.permission == AppPermission.location
                  ? PermissionStatus.notRequired
                  : PermissionStatus.unsupported),
        ),
        isTrue,
      );
      await expectLater(
        permissions.openSettings(AppPermission.camera),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        permissions.request(AppPermission.camera),
        throwsA(isA<ApiFailure>()),
      );
      expect(nativeCalls, 0);
    },
  );

  test(
    'iOS maps native states and requests only the selected permission',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        methods.add(call.method);
        if (call.method == 'check') {
          return {
            ...state(),
            'photos': 'denied',
            'battery': 'unsupported',
            'autostart': 'unsupported',
          };
        }
        expect((call.arguments as Map)['permission'], 'photos');
        return true;
      });
      final result = await permissions.check();
      expect(result[3].status, PermissionStatus.notRequired);
      expect(
        result
            .singleWhere((item) => item.permission == AppPermission.autostart)
            .status,
        PermissionStatus.unsupported,
      );
      expect(
        result
            .singleWhere((item) => item.permission == AppPermission.location)
            .status,
        PermissionStatus.notRequired,
      );
      expect(result[2].status, PermissionStatus.denied);
      expect(await permissions.request(AppPermission.photos), isTrue);
      expect(methods, ['check', 'request']);
    },
  );

  test('Windows permissions require no Android authorization', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final states = await permissions.check();
    expect(
      states
          .singleWhere((state) => state.permission == AppPermission.photos)
          .status,
      PermissionStatus.notRequired,
    );
    expect(states.first.status, PermissionStatus.unsupported);
    expect(
      states
          .singleWhere((item) => item.permission == AppPermission.autostart)
          .status,
      PermissionStatus.denied,
    );
    expect(
      states
          .singleWhere((item) => item.permission == AppPermission.location)
          .status,
      PermissionStatus.notRequired,
    );
  });

  test(
    'iOS location is required only for the selected location mode',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      for (final nativeState in ['granted', 'denied', 'needsConfirmation']) {
        messenger.setMockMethodCallHandler(
          permissionChannel,
          (_) async => {
            ...state(),
            'battery': 'unsupported',
            'autostart': 'unsupported',
            'location': nativeState,
          },
        );
        final unused = await permissions.check();
        expect(
          unused
              .singleWhere((item) => item.permission == AppPermission.location)
              .status,
          PermissionStatus.notRequired,
        );
        final required = await const AppPermissions(
          locationRequired: true,
        ).check();
        expect(
          required
              .singleWhere((item) => item.permission == AppPermission.location)
              .status
              .name,
          nativeState,
        );
      }
    },
  );

  test(
    'Android location never requests a runtime grant for background service',
    () async {
      final selected = <MethodCall>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        selected.add(call);
        return {...state(), 'location': 'denied'};
      });
      final states = await const AppPermissions(locationRequired: true).check();
      expect(
        states
            .singleWhere((item) => item.permission == AppPermission.location)
            .status,
        PermissionStatus.notRequired,
      );
      expect(selected.map((call) => call.method), ['check']);
    },
  );

  test(
    'iOS background mode uses native runtime with mode and deadline',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final runtime = BackgroundRuntime();
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      expect(runtime.supported, true);
      await runtime.configure(
        mode: BackgroundServiceMode.silentAudio,
        deadline: deadline,
      );
      expect(await runtime.setEnabled(true), true);
      expect(runtime.enabled, true);
      expect(calls.last.arguments, {
        'enabled': true,
        'mode': 'silentAudio',
        'deadlineEpochMs': deadline.millisecondsSinceEpoch,
      });
      expect(await runtime.setEnabled(false), true);
      expect(runtime.enabled, false);
    },
  );

  test(
    'Windows monitoring uses the desktop process without Android services',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final runtime = BackgroundRuntime();
      expect(await runtime.setEnabled(true), isTrue);
      expect(runtime.enabled, isTrue);
      expect(calls, isEmpty);
      expect(await runtime.setEnabled(false), isTrue);
      expect(runtime.enabled, isFalse);
    },
  );

  test(
    'request returns the actual runtime result and targets one permission',
    () async {
      final selected = <String>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        expect(call.method, 'request');
        selected.add((call.arguments as Map)['permission'] as String);
        return selected.length == 1;
      });
      expect(await permissions.request(AppPermission.camera), isTrue);
      expect(await permissions.request(AppPermission.notifications), isFalse);
      expect(selected, ['camera', 'notifications']);
    },
  );

  test('runtime failure is not reported as granted', () async {
    messenger.setMockMethodCallHandler(permissionChannel, (_) async {
      throw PlatformException(code: 'permission_busy', message: '另一项权限申请尚未完成');
    });
    await expectLater(
      permissions.request(AppPermission.camera),
      throwsA(isA<ApiFailure>()),
    );
  });

  test(
    'background refuses missing notifications or battery exemption without any prompt',
    () async {
      for (final response in [
        state(notifications: 'denied'),
        state(battery: 'denied'),
      ]) {
        messenger.setMockMethodCallHandler(
          permissionChannel,
          (_) async => response,
        );
        final runtime = BackgroundRuntime();
        expect(await runtime.setEnabled(true), isFalse);
        expect(runtime.enabled, isFalse);
        expect(calls.last.method, 'setEnabled');
        expect(calls.last.arguments, {
          'enabled': false,
          'mode': 'native',
          'deadlineEpochMs': null,
        });
      }
      expect(legacyPermissionCalls, 0);
    },
  );

  test(
    'permission read failure prevents background plugin initialization',
    () async {
      messenger.setMockMethodCallHandler(permissionChannel, (_) async {
        throw PlatformException(code: 'permission_check_failed');
      });
      expect(await BackgroundRuntime().setEnabled(true), isFalse);
      expect(calls.single.method, 'setEnabled');
      expect(calls.single.arguments, {
        'enabled': false,
        'mode': 'native',
        'deadlineEpochMs': null,
      });
      expect(legacyPermissionCalls, 0);
    },
  );

  test(
    'granted gate calls only the runtime service and reacts to revocation',
    () async {
      var response = state();
      final permissionMethods = <String>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        permissionMethods.add(call.method);
        return response;
      });
      final runtime = BackgroundRuntime();
      expect(await runtime.setEnabled(true), isTrue);
      expect(runtime.enabled, isTrue);
      expect(calls.map((call) => call.method), ['setEnabled']);
      final config = calls.first.arguments as Map;
      expect(config, {
        'enabled': true,
        'mode': 'native',
        'deadlineEpochMs': null,
      });
      response = state(notifications: 'denied');
      expect(await runtime.setEnabled(true), isFalse);
      expect(runtime.enabled, isFalse);
      expect(calls.last.method, 'setEnabled');
      expect(calls.last.arguments, {
        'enabled': false,
        'mode': 'native',
        'deadlineEpochMs': null,
      });
      expect(permissionMethods, ['check', 'check']);
      expect(legacyPermissionCalls, 0);
    },
  );

  test(
    'stops an already native-started service before Dart has enabled it',
    () async {
      final runtime = BackgroundRuntime();
      expect(runtime.enabled, isFalse);
      expect(await runtime.setEnabled(false), isTrue);
      expect(calls.single.method, 'setEnabled');
      expect(calls.single.arguments, {
        'enabled': false,
        'mode': 'native',
        'deadlineEpochMs': null,
      });
    },
  );

  test('Windows unknown StartupApps status remains unverified', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    messenger.setMockMethodCallHandler(
      AppAutostart.channel,
      (_) async => {'enabled': false, 'permission': 'needsConfirmation'},
    );
    final states = await permissions.check();
    expect(
      states
          .singleWhere((item) => item.permission == AppPermission.autostart)
          .status,
      PermissionStatus.needsConfirmation,
    );
  });

  test(
    'Windows consent prepares an item before checking its authorization',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(AppAutostart.channel, (call) async {
        methods.add(call.method);
        if (call.method == 'status') {
          return {'enabled': false, 'permission': 'granted'};
        }
        return null;
      });
      expect(await permissions.request(AppPermission.autostart), isTrue);
      expect(methods, ['prepare', 'status']);
    },
  );

  test(
    'Windows denial opens the now-discoverable item without bypassing authorization',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      for (final status in ['denied', 'needsConfirmation']) {
        final methods = <String>[];
        messenger.setMockMethodCallHandler(AppAutostart.channel, (call) async {
          methods.add(call.method);
          if (call.method == 'status') {
            return {'enabled': false, 'permission': status};
          }
          if (call.method == 'openSettings') return true;
          return null;
        });
        expect(await permissions.request(AppPermission.autostart), isFalse);
        expect(methods, ['prepare', 'status', 'openSettings', 'status']);
      }
    },
  );

  test(
    'Windows preparation failure neither navigates nor reports success',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(AppAutostart.channel, (call) async {
        methods.add(call.method);
        throw PlatformException(code: 'prepare_failed');
      });
      await expectLater(
        permissions.request(AppPermission.autostart),
        throwsA(isA<ApiFailure>()),
      );
      expect(methods, ['prepare']);
    },
  );
}
