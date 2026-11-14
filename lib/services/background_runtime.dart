import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';

import 'app_permissions.dart';

/// Keeps the Android Flutter isolate alive while classroom monitoring is active.
/// Other platforms must provide their own lifecycle implementation.
class BackgroundRuntime {
  final AppPermissions permissions;
  BackgroundRuntime({this.permissions = const AppPermissions()});

  bool _enabled = false;
  Future<bool> _operation = Future<bool>.value(true);

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get enabled => _supported && _enabled;

  Future<bool> setEnabled(bool enabled) {
    _operation = _operation.then((_) => _setEnabled(enabled));
    return _operation;
  }

  Future<bool> _setEnabled(bool enabled) async {
    if (!_supported) return !enabled;
    try {
      if (!enabled) {
        if (!_enabled && !FlutterBackground.isBackgroundExecutionEnabled) {
          return true;
        }
        final stopped = await FlutterBackground.disableBackgroundExecution();
        if (stopped) _enabled = false;
        return stopped;
      }
      final states = await permissions.check();
      final required = [AppPermission.notifications, AppPermission.battery];
      final allowed = required.every(
        (permission) => states.any(
          (state) =>
              state.permission == permission &&
              state.status == PermissionStatus.granted,
        ),
      );
      if (!allowed) {
        if (_enabled || FlutterBackground.isBackgroundExecutionEnabled) {
          await FlutterBackground.disableBackgroundExecution();
        }
        _enabled = false;
        return false;
      }
      if (this.enabled) return true;

      final initialized = await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'ykt_helper',
          notificationText: '正在监控课堂，按设置自动签到和答题',
          // flutter_background 1.3.1 maps max to channel importance 2 (LOW),
          // whereas normal maps to 0 (NONE) and hides the service notification.
          notificationImportance: AndroidNotificationImportance.max,
          notificationIcon: AndroidResource(name: 'ic_background'),
          enableWifiLock: true,
          showBadge: false,
          // Permission checks above are read-only; only the explained and
          // confirmed settings flow may request this exemption. Disabling the
          // plugin prompt also closes the race with permission revocation.
          shouldRequestBatteryOptimizationsOff: false,
        ),
      );
      if (!initialized) return false;
      _enabled = await FlutterBackground.enableBackgroundExecution();
      return _enabled;
    } on Exception {
      if (enabled) {
        try {
          if (_enabled || FlutterBackground.isBackgroundExecutionEnabled) {
            await FlutterBackground.disableBackgroundExecution();
          }
        } on Exception {
          // Keep the failure visible through the caller's background warning.
        }
        _enabled = false;
      }
      return false;
    }
  }
}
