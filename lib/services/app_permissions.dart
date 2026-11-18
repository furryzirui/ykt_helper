import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'app_autostart.dart';

enum AppPermission {
  camera,
  notifications,
  photos,
  battery,
  autostart,
  location,
}

enum PermissionStatus {
  granted,
  denied,
  notRequired,
  unsupported,
  needsConfirmation,
}

class AppPermissionState {
  final AppPermission permission;
  final PermissionStatus status;
  const AppPermissionState({required this.permission, required this.status});
}

/// Reads current authorization without requesting it. The UI must explain and
/// confirm each system-settings navigation before calling [openSettings].
class AppPermissions {
  static const _channel = MethodChannel('ykt_helper/app_permissions');
  final bool locationRequired;
  const AppPermissions({this.locationRequired = false});

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<List<AppPermissionState>> check() async {
    if (!_supported) {
      final windows =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
      final autostart = windows
          ? PermissionStatus.values.byName(
              await const AppAutostart().permissionStatus(),
            )
          : PermissionStatus.unsupported;
      return [
        for (final permission in AppPermission.values)
          AppPermissionState(
            permission: permission,
            status: permission == AppPermission.location
                ? PermissionStatus.notRequired
                : !windows || permission == AppPermission.camera
                ? PermissionStatus.unsupported
                : permission == AppPermission.autostart
                ? autostart
                : PermissionStatus.notRequired,
          ),
      ];
    }
    try {
      final values = await _channel.invokeMapMethod<String, String>('check');
      return [
        for (final permission in AppPermission.values)
          AppPermissionState(
            permission: permission,
            status:
                permission == AppPermission.location &&
                    (defaultTargetPlatform != TargetPlatform.iOS ||
                        !locationRequired)
                ? PermissionStatus.notRequired
                : defaultTargetPlatform == TargetPlatform.iOS &&
                      permission == AppPermission.battery &&
                      values?[permission.name] == 'unsupported'
                ? PermissionStatus.notRequired
                : PermissionStatus.values.firstWhere(
                    (status) => status.name == values?[permission.name],
                    orElse: () => throw const ApiFailure('无法读取应用权限状态，请重试'),
                  ),
          ),
      ];
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法读取应用权限状态，请重试');
    } on MissingPluginException {
      throw const ApiFailure('当前平台暂不支持检查应用权限');
    } on TypeError {
      throw const ApiFailure('无法读取应用权限状态，请重试');
    }
  }

  Future<void> openSettings(AppPermission permission) async {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        permission == AppPermission.autostart) {
      try {
        final opened = await AppAutostart.channel.invokeMethod<bool>(
          'openSettings',
        );
        if (opened != true) throw const ApiFailure('无法打开开机启动设置');
        return;
      } on PlatformException catch (error) {
        throw ApiFailure(error.message ?? '无法打开开机启动设置');
      } on MissingPluginException {
        throw const ApiFailure('无法打开开机启动设置');
      }
    }
    if (!_supported) throw const ApiFailure('当前平台暂不支持打开应用权限设置');
    try {
      final opened = await _channel.invokeMethod<bool>('openSettings', {
        'permission': permission.name,
      });
      if (opened != true) throw const ApiFailure('无法打开系统设置，请在系统设置中查找本应用');
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法打开系统设置，请在系统设置中查找本应用');
    } on MissingPluginException {
      throw const ApiFailure('当前平台暂不支持打开应用权限设置');
    }
  }

  /// Call only after the UI has explained the purpose and received confirmation.
  /// Android tries its single-permission dialog, falling back to app settings
  /// when that dialog cannot be used. False never means authorization succeeded.
  Future<bool> request(AppPermission permission) async {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        permission == AppPermission.autostart) {
      const autostart = AppAutostart();
      await autostart.prepare();
      if (await autostart.permissionStatus() == 'granted') return true;
      await openSettings(permission);
      return await autostart.permissionStatus() == 'granted';
    }
    if (!_supported) throw const ApiFailure('当前平台暂不支持申请应用权限');
    try {
      return await _channel.invokeMethod<bool>('request', {
            'permission': permission.name,
          }) ==
          true;
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法申请权限，请在应用权限中重试');
    } on MissingPluginException {
      throw const ApiFailure('当前平台暂不支持申请应用权限');
    }
  }
}
