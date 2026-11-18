import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_permissions.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/ui/automation_page.dart';
import 'package:ykt_helper/ui/permissions_page.dart';
import 'package:ykt_helper/ui/settings_page.dart';

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Background extends BackgroundRuntime {
  bool active = false;
  @override
  bool get enabled => active;
  @override
  Future<bool> setEnabled(bool enabled) async {
    active = enabled;
    return true;
  }
}

class _Controller extends AppController {
  final _Background runtime;
  DateTime? deadline;
  final choices = <int>[];
  int starts = 0, confirmations = 0;
  _Controller(this.runtime)
    : super(
        store: _Store(),
        background: runtime,
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
    account = const Account(id: 'user', name: '学生', school: '');
    settings = AppSettings(autoEnter: true);
  }
  @override
  DateTime? get serviceDeadline => deadline;
  @override
  Duration? get serviceRemaining => deadline?.difference(DateTime.now());
  @override
  Future<void> setServiceTimeout(int minutes) async {
    choices.add(minutes);
    settings.serviceTimeoutMinutes = minutes;
    deadline = minutes == 0
        ? null
        : DateTime.now().add(Duration(minutes: minutes));
    notifyListeners();
  }

  @override
  Future<void> setSystemService(
    bool enabled, {
    bool iosConfirmed = false,
  }) async {
    if (enabled) starts++;
    if (iosConfirmed) confirmations++;
    runtime.active = enabled;
    notifyListeners();
  }

  @override
  Future<void> saveSettings([AppSettings? next]) async {
    settings = AppSettings.fromJson((next ?? settings).toJson());
    notifyListeners();
  }
}

class _Permissions extends AppPermissions {
  PermissionStatus location = PermissionStatus.needsConfirmation;
  int requests = 0;
  @override
  Future<List<AppPermissionState>> check() async => [
    for (final permission in AppPermission.values)
      AppPermissionState(
        permission: permission,
        status: permission == AppPermission.location
            ? location
            : PermissionStatus.notRequired,
      ),
  ];
  @override
  Future<bool> request(AppPermission permission) async {
    requests++;
    location = PermissionStatus.granted;
    return true;
  }
}

Future<void> _show(WidgetTester tester, Widget page) async {
  await tester.binding.setSurfaceSize(const Size(800, 1500));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: page)));
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('$platform 仅提供本机后台实现并兼容默认静音偏好', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final controller = _Controller(_Background());
      await _show(tester, AutomationPage(controller: controller));
      final field = tester
          .widget<DropdownButtonFormField<BackgroundServiceMode>>(
            find.byType(DropdownButtonFormField<BackgroundServiceMode>),
          );
      expect(field.initialValue, BackgroundServiceMode.native);
      expect(field.onChanged, isNull);
      expect(
        find.text(platform == TargetPlatform.android ? '前台服务' : '应用进程'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('窄屏大字号下服务说明和24小时计时无溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(
      () => tester.platformDispatcher.clearTextScaleFactorTestValue(),
    );
    final controller = _Controller(_Background()..active = true)
      ..deadline = DateTime.now().add(const Duration(hours: 24));
    await _show(tester, SettingsPage(controller: controller));
    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpAndSettle();
    expect(find.text('保持自动化后台运行，关闭后仅前台运行，可减少耗电'), findsOneWidget);
    expect(find.byKey(const ValueKey('service-countdown')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('运行后显示永不，重选重置倒计时且取消不改变', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = _Background()..active = true;
    final controller = _Controller(runtime);
    await _show(tester, SettingsPage(controller: controller));
    expect(find.byKey(const ValueKey('service-timeout')), findsOneWidget);
    expect(find.text('永不'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('service-timeout')));
    await tester.pumpAndSettle();
    for (final value in [0, 10, 120, 1440]) {
      expect(find.byKey(ValueKey('service-timeout-$value')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('service-timeout-10')));
    await tester.pumpAndSettle();
    expect(controller.choices, [10]);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('service-countdown'))).data,
      matches(r'^0?9:5\d$|^10:00$'),
    );
    await tester.tap(find.byKey(const ValueKey('service-timeout')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(controller.choices, [10]);
    await tester.tap(find.byKey(const ValueKey('service-timeout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-timeout-0')));
    await tester.pumpAndSettle();
    expect(controller.choices, [10, 0]);
    expect(find.text('永不'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Windows保留服务勾选并允许定时退出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Background());
    await _show(tester, SettingsPage(controller: controller));
    expect(find.byType(Switch), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.text('到时若在后台则退出应用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name}自动启动服务时定时显示永不并禁用，关闭后可重新选择', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final controller = _Controller(_Background()..active = true)
        ..deadline = DateTime.now().add(const Duration(minutes: 10));
      controller.settings.autoStartService = true;
      await _show(tester, SettingsPage(controller: controller));
      final tile = find.descendant(
        of: find.byKey(const ValueKey('service-timeout')),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(tile).onTap, isNull);
      expect(find.text('请先关闭自动启动服务后设置定时关闭'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('service-countdown')))
            .data,
        '永不',
      );
      await controller.saveSettings(
        AppSettings.fromJson(controller.settings.toJson())
          ..autoStartService = false,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(tile).onTap, isNotNull);
      await tester.tap(find.byKey(const ValueKey('service-timeout')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('service-timeout-10')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('定时弹窗期间启用自动启动服务则丢弃先前时间选择', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Background()..active = true);
    await _show(tester, SettingsPage(controller: controller));
    await tester.tap(find.byKey(const ValueKey('service-timeout')));
    await tester.pumpAndSettle();
    await controller.saveSettings(
      AppSettings.fromJson(controller.settings.toJson())
        ..autoStartService = true,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('service-timeout-10')));
    await tester.pumpAndSettle();
    expect(controller.choices, isEmpty);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('service-countdown'))).data,
      '永不',
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('iOS每次手动启用均确认，取消不启动', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Background());
    await _show(tester, SettingsPage(controller: controller));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法保证整节课持续运行'), findsOneWidget);
    expect(controller.starts, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.starts, 0);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认开启'));
    await tester.pumpAndSettle();
    expect(controller.starts, 1);
    expect(controller.confirmations, 1);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('iOS方案切换经确认保存，自动启动也确认', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Background());
    await _show(tester, AutomationPage(controller: controller));
    expect(find.text('iOS 不支持应用自启动'), findsOneWidget);
    await tester.tap(
      find.byType(DropdownButtonFormField<BackgroundServiceMode>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('画中画保活').last);
    await tester.pumpAndSettle();
    expect(
      controller.settings.backgroundMode,
      BackgroundServiceMode.silentAudio,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      controller.settings.backgroundMode,
      BackgroundServiceMode.silentAudio,
    );
    expect(find.text('静音音频保活'), findsOneWidget);
    expect(find.text('画中画保活'), findsNothing);
    await tester.tap(
      find.byType(DropdownButtonFormField<BackgroundServiceMode>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('画中画保活').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    expect(
      controller.settings.backgroundMode,
      BackgroundServiceMode.pictureInPicture,
    );
    expect(controller.settings.iosBackgroundConsentMode, 'pictureInPicture');
    await tester.tap(find.byKey(const ValueKey('auto-start-service')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    // A model or controller refresh can replace the settings while consent is
    // pending. The confirmed edit must target the latest draft.
    await controller.saveSettings(
      AppSettings.fromJson(controller.settings.toJson()),
    );
    await tester.pump();
    await tester.tap(find.text('确认开启'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoStartService, true);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('iOS选择定位先保存，手动开启和自动启动前才申请授权', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('ykt_helper/app_permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    var granted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'request') {
        granted = true;
        return true;
      }
      return {
        for (final permission in AppPermission.values)
          permission.name: permission == AppPermission.location
              ? granted
                    ? 'granted'
                    : 'needsConfirmation'
              : 'notRequired',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = _Controller(_Background());
    await _show(tester, AutomationPage(controller: controller));
    await tester.tap(
      find.byType(DropdownButtonFormField<BackgroundServiceMode>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('持续定位保活').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    expect(controller.settings.backgroundMode, BackgroundServiceMode.location);
    expect(calls, isEmpty);
    expect(controller.starts, 0);
    await tester.tap(find.byKey(const ValueKey('auto-start-service')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认开启'));
    await tester.pumpAndSettle();
    expect(find.textContaining('定位数据不会上传'), findsOneWidget);
    expect(controller.settings.autoStartService, false);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoStartService, false);
    expect(calls, ['check']);
    await tester.pumpWidget(const SizedBox());
    await _show(tester, SettingsPage(controller: controller));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认开启'));
    await tester.pumpAndSettle();
    expect(controller.starts, 0);
    await tester.tap(find.text('继续授权'));
    await tester.pumpAndSettle();
    expect(calls, ['check', 'check', 'request', 'check']);
    expect(controller.starts, 1);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('iOS后台方案只保留三项且均允许永不定时', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Background()..active = true);
    await _show(tester, AutomationPage(controller: controller));
    await tester.tap(
      find.byType(DropdownButtonFormField<BackgroundServiceMode>),
    );
    await tester.pumpAndSettle();
    final menu = tester.widget<DropdownButton<BackgroundServiceMode>>(
      find.byType(DropdownButton<BackgroundServiceMode>),
    );
    expect(menu.items!.map((item) => item.value), [
      BackgroundServiceMode.silentAudio,
      BackgroundServiceMode.pictureInPicture,
      BackgroundServiceMode.location,
    ]);
    for (final label in ['静音音频保活', '画中画保活', '持续定位保活']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    expect(find.textContaining('长任务'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    final autoStart = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('auto-start-service')),
    );
    expect(autoStart.onChanged, isNotNull);
    await tester.pumpWidget(const SizedBox());
    for (final mode in [
      BackgroundServiceMode.silentAudio,
      BackgroundServiceMode.pictureInPicture,
      BackgroundServiceMode.location,
    ]) {
      controller.settings.backgroundMode = mode;
      await _show(tester, SettingsPage(controller: controller));
      await tester.tap(find.byKey(const ValueKey('service-timeout')));
      await tester.pumpAndSettle();
      for (final minutes in [10, 120, 1440, 0]) {
        expect(
          find.byKey(ValueKey('service-timeout-$minutes')),
          findsOneWidget,
        );
      }
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    }
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('iOS定位保活权限经解释请求，其他模式显示无需授权', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final permissions = _Permissions();
    await _show(tester, PermissionsPage(permissions: permissions));
    final row = find.widgetWithText(ListTile, '定位');
    expect(tester.widget<ListTile>(row).onTap, isNull);
    await tester.pumpWidget(const SizedBox());
    await _show(
      tester,
      PermissionsPage(permissions: permissions, locationRequired: true),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.textContaining('定位数据不会上传'), findsOneWidget);
    expect(permissions.requests, 0);
    await tester.tap(find.text('继续授权'));
    await tester.pumpAndSettle();
    expect(permissions.requests, 1);
    expect(
      find.descendant(of: row, matching: find.text('已允许')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
