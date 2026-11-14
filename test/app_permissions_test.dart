import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_permissions.dart';
import 'package:ykt_helper/services/background_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissionChannel = MethodChannel('ykt_helper/app_permissions');
  const backgroundChannel = MethodChannel('flutter_background');
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
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    for (final channel in [
      permissionChannel,
      backgroundChannel,
      legacyChannel,
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
        result.every((item) => item.status == PermissionStatus.unsupported),
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
          return {...state(), 'photos': 'denied', 'battery': 'unsupported'};
        }
        expect((call.arguments as Map)['permission'], 'photos');
        return true;
      });
      final result = await permissions.check();
      expect(result.last.status, PermissionStatus.notRequired);
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
    expect(
      states.every((state) => state.status == PermissionStatus.notRequired),
      isTrue,
    );
  });

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
        expect(calls, isEmpty);
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
      expect(calls, isEmpty);
      expect(legacyPermissionCalls, 0);
    },
  );

  test(
    'granted background gate disables plugin prompts and reacts to revocation',
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
      expect(calls.map((call) => call.method), [
        'initialize',
        'enableBackgroundExecution',
      ]);
      final config = calls.first.arguments as Map;
      expect(config['android.shouldRequestBatteryOptimizationsOff'], isFalse);
      expect(config['android.notificationImportance'], 2);
      response = state(notifications: 'denied');
      expect(await runtime.setEnabled(true), isFalse);
      expect(runtime.enabled, isFalse);
      expect(calls.last.method, 'disableBackgroundExecution');
      expect(permissionMethods, ['check', 'check']);
      expect(legacyPermissionCalls, 0);
    },
  );
}
