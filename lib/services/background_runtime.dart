import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_permissions.dart';

/// Android service and Activity share one engine and one automation owner.
class BackgroundRuntime {
  static const _channel = MethodChannel('ykt_helper/background_runtime');
  final AppPermissions permissions;
  BackgroundRuntime({this.permissions = const AppPermissions()});

  bool _enabled = false;
  int _pendingOperations = 0;
  Future<bool> _operation = Future<bool>.value(true);
  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _desktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get supported => _supported;
  bool get busy => _pendingOperations > 0;
  bool get enabled => (_supported || _desktop) && _enabled;

  Future<bool> setEnabled(bool enabled) {
    _pendingOperations++;
    final operation = _operation
        .catchError((_) => false)
        .then((_) => _setEnabled(enabled));
    _operation = operation.then(
      (value) {
        _pendingOperations--;
        return value;
      },
      onError: (Object _, StackTrace _) {
        _pendingOperations--;
        return false;
      },
    );
    return operation;
  }

  Future<bool> _native(bool enabled) async =>
      await _channel.invokeMethod<bool>('setEnabled', {'enabled': enabled}) ==
      true;

  Future<bool> _setEnabled(bool enabled) async {
    if (_desktop) {
      _enabled = enabled;
      return true;
    }
    if (!_supported) return !enabled;
    try {
      if (!enabled) {
        // A native boot launch can already run before Dart has loaded settings.
        final stopped = await _native(false);
        if (stopped) _enabled = false;
        return stopped;
      }
      final states = await permissions.check();
      final allowed = [AppPermission.notifications, AppPermission.battery]
          .every(
            (permission) => states.any(
              (state) =>
                  state.permission == permission &&
                  state.status == PermissionStatus.granted,
            ),
          );
      if (!allowed) {
        await _native(false);
        _enabled = false;
        return false;
      }
      _enabled = await _native(true);
      return _enabled;
    } on Exception {
      try {
        await _native(false);
      } on Exception {
        // Retain failure without letting cleanup hide the original result.
      }
      _enabled = false;
      return false;
    }
  }
}
