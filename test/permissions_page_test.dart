import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/services/app_permissions.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/permissions_page.dart';

class _Permissions extends AppPermissions {
  final states = <AppPermission, PermissionStatus>{
    AppPermission.camera: PermissionStatus.denied,
    AppPermission.notifications: PermissionStatus.granted,
    AppPermission.photos: PermissionStatus.notRequired,
    AppPermission.battery: PermissionStatus.denied,
  };
  final opened = <AppPermission>[];
  final requested = <AppPermission>[];
  bool grantRequest = false;
  int checks = 0;
  Object? checkError, openError;

  @override
  Future<List<AppPermissionState>> check() async {
    checks++;
    if (checkError != null) throw checkError!;
    return [
      for (final entry in states.entries)
        AppPermissionState(permission: entry.key, status: entry.value),
    ];
  }

  @override
  Future<void> openSettings(AppPermission permission) async {
    if (openError != null) throw openError!;
    opened.add(permission);
  }

  @override
  Future<bool> request(AppPermission permission) async {
    if (openError != null) throw openError!;
    requested.add(permission);
    if (grantRequest) states[permission] = PermissionStatus.granted;
    return grantRequest;
  }
}

Future<void> _show(WidgetTester tester, _Permissions permissions) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: rainTheme(Brightness.light),
      home: PermissionsPage(permissions: permissions),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(String text) => find.widgetWithText(ListTile, text);

Future<void> _gate(
  WidgetTester tester,
  _Permissions permissions,
  AppPermission permission,
  ValueChanged<bool> result,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result(
              await ensureAppPermission(
                context,
                permission,
                permissions: permissions,
              ),
            ),
            child: const Text('执行操作'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows actual statuses; modern album needs no permission', (
    tester,
  ) async {
    final permissions = _Permissions();
    await _show(tester, permissions);
    expect(permissions.checks, 1);
    expect(find.text('未允许'), findsOneWidget);
    expect(find.text('已允许'), findsOneWidget);
    expect(find.text('无需授权'), findsOneWidget);
    expect(find.text('仍受优化'), findsOneWidget);
    expect(tester.widget<ListTile>(_row('保存到相册')).onTap, isNull);
    await tester.tap(_row('保存到相册'));
    await tester.pumpAndSettle();
    expect(permissions.opened, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('无需系统授权的权限显示无需授权且不打开申请页面', (tester) async {
    final permissions = _Permissions();
    for (final permission in AppPermission.values) {
      permissions.states[permission] = PermissionStatus.notRequired;
    }
    await _show(tester, permissions);
    expect(find.text('无需授权'), findsNWidgets(4));
    expect(find.text('暂不支持'), findsNothing);
    for (final name in ['相机', '通知', '保存到相册', '电池优化']) {
      expect(tester.widget<ListTile>(_row(name)).onTap, isNull);
      await tester.tap(_row(name));
    }
    await tester.pumpAndSettle();
    expect(permissions.opened, isEmpty);
    expect(permissions.requested, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'both denied and granted settings require explanation confirmation',
    (tester) async {
      final permissions = _Permissions();
      await _show(tester, permissions);
      await tester.tap(_row('相机'));
      await tester.pumpAndSettle();
      expect(find.textContaining('用于扫描课堂二维码'), findsOneWidget);
      expect(find.textContaining('系统弹窗'), findsOneWidget);
      expect(permissions.opened, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(permissions.opened, isEmpty);
      await tester.tap(_row('相机'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续授权'));
      await tester.pumpAndSettle();
      expect(permissions.opened, isEmpty);
      expect(permissions.requested, [AppPermission.camera]);
      await tester.tap(_row('通知'));
      await tester.pumpAndSettle();
      expect(find.textContaining('用于显示后台课堂运行通知'), findsOneWidget);
      expect(permissions.opened, isEmpty);
      await tester.tap(find.text('前往设置'));
      await tester.pumpAndSettle();
      expect(permissions.opened, [AppPermission.notifications]);
    },
  );

  testWidgets('returning to foreground refreshes permission states', (
    tester,
  ) async {
    final permissions = _Permissions();
    await _show(tester, permissions);
    permissions.states[AppPermission.camera] = PermissionStatus.granted;
    permissions.states[AppPermission.battery] = PermissionStatus.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(permissions.checks, 2);
    expect(find.text('已允许'), findsNWidgets(2));
    expect(find.text('已取消优化'), findsOneWidget);
    expect(find.text('仍受优化'), findsNothing);
  });

  testWidgets(
    'failed or incomplete checks show retry without guessing status',
    (tester) async {
      final permissions = _Permissions()
        ..checkError = StateError('native failure');
      await _show(tester, permissions);
      expect(find.text('无法读取应用权限，请重试'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(find.textContaining('native failure'), findsNothing);
      permissions.checkError = null;
      permissions.states.remove(AppPermission.camera);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取应用权限，请重试'), findsOneWidget);
      permissions.states[AppPermission.camera] = PermissionStatus.granted;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(4));
      expect(find.text('无法读取应用权限，请重试'), findsNothing);
    },
  );

  testWidgets('settings launch errors stay visible without losing page state', (
    tester,
  ) async {
    final permissions = _Permissions()
      ..openError = StateError('system failure');
    await _show(tester, permissions);
    await tester.tap(_row('相机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续授权'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开系统设置，请在系统设置中找到本应用后调整权限'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(4));
    expect(find.textContaining('system failure'), findsNothing);
  });

  testWidgets(
    'permission gate continues only when permission already suffices',
    (tester) async {
      final permissions = _Permissions();
      bool? result;
      await _gate(
        tester,
        permissions,
        AppPermission.photos,
        (value) => result = value,
      );
      await tester.tap(find.text('执行操作'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      result = null;
      await _gate(
        tester,
        permissions,
        AppPermission.notifications,
        (value) => result = value,
      );
      await tester.tap(find.text('执行操作'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(permissions.opened, isEmpty);
    },
  );

  testWidgets(
    'denied gate requires confirmation and never resumes the operation',
    (tester) async {
      final permissions = _Permissions();
      bool? result;
      await _gate(
        tester,
        permissions,
        AppPermission.camera,
        (value) => result = value,
      );
      await tester.tap(find.text('执行操作'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(permissions.opened, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(permissions.opened, isEmpty);
      result = null;
      await tester.tap(find.text('执行操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续授权'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(permissions.opened, isEmpty);
      expect(permissions.requested, [AppPermission.camera]);
    },
  );

  testWidgets('unsupported and failed gates do not request or assume access', (
    tester,
  ) async {
    final permissions = _Permissions();
    permissions.states[AppPermission.camera] = PermissionStatus.unsupported;
    bool? result;
    await _gate(
      tester,
      permissions,
      AppPermission.camera,
      (value) => result = value,
    );
    await tester.tap(find.text('执行操作'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.text('当前平台暂不支持此权限功能'), findsOneWidget);
    expect(permissions.opened, isEmpty);
    permissions.checkError = StateError('native failure');
    await tester.tap(find.text('执行操作'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.text('无法读取应用权限，请重试'), findsOneWidget);
    expect(permissions.opened, isEmpty);
  });

  testWidgets(
    'runtime grant rechecks status and continues the pending operation',
    (tester) async {
      final permissions = _Permissions()..grantRequest = true;
      bool? result;
      await _gate(
        tester,
        permissions,
        AppPermission.camera,
        (value) => result = value,
      );
      await tester.tap(find.text('执行操作'));
      await tester.pumpAndSettle();
      expect(permissions.requested, isEmpty);
      await tester.tap(find.text('继续授权'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(permissions.checks, 2);
      expect(permissions.requested, [AppPermission.camera]);
      expect(permissions.opened, isEmpty);
    },
  );

  testWidgets('permission page refreshes after direct runtime authorization', (
    tester,
  ) async {
    final permissions = _Permissions()..grantRequest = true;
    await _show(tester, permissions);
    await tester.tap(_row('相机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续授权'));
    await tester.pumpAndSettle();
    expect(find.text('已允许'), findsNWidgets(2));
    expect(permissions.requested, [AppPermission.camera]);
    expect(permissions.opened, isEmpty);
  });
}
