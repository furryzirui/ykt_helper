import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'app_permissions.dart';

class BackgroundRuntimeState {
  final bool enabled;
  final DateTime? deadline;
  final String? reason;
  final String? message;
  const BackgroundRuntimeState({
    required this.enabled,
    this.deadline,
    this.reason,
    this.message,
  });

  factory BackgroundRuntimeState.fromMap(Map<dynamic, dynamic> value) =>
      BackgroundRuntimeState(
        enabled: value['enabled'] == true,
        deadline: value['deadlineEpochMs'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (value['deadlineEpochMs'] as num).toInt(),
              )
            : null,
        reason: value['reason'] is String ? value['reason'] as String : null,
        message: value['message'] is String ? value['message'] as String : null,
      );
}

/// Native execution and the foreground UI share a single automation owner.
class BackgroundRuntime {
  static const channel = MethodChannel('ykt_helper/background_runtime');
  final AppPermissions permissions;
  BackgroundRuntime({this.permissions = const AppPermissions()});

  bool _enabled = false;
  int _pendingOperations = 0;
  Future<bool> _operation = Future<bool>.value(true);
  BackgroundServiceMode _mode = BackgroundServiceMode.native;
  DateTime? _deadline;
  String? failureReason;
  String? failureMessage;
  void Function(BackgroundRuntimeState state)? _listener;
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get _desktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get supported => _supported;
  bool get busy => _pendingOperations > 0;
  bool get enabled => (_supported || _desktop) && _enabled;

  void setStateListener(void Function(BackgroundRuntimeState state)? listener) {
    _listener = listener;
    channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method != 'stateChanged' || call.arguments is! Map) {
                return;
              }
              final state = BackgroundRuntimeState.fromMap(
                call.arguments as Map,
              );
              _enabled = state.enabled;
              failureReason = state.reason;
              failureMessage = state.message;
              _listener?.call(state);
            },
    );
  }

  Map<String, Object?> get _arguments => {
    'mode': _mode.name,
    'deadlineEpochMs': _deadline?.millisecondsSinceEpoch,
  };

  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {
    _mode = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? mode
        : BackgroundServiceMode.native;
    _deadline = deadline;
    if (!_supported) return;
    try {
      await channel.invokeMethod<Object?>('configure', _arguments);
    } on MissingPluginException {
      // setEnabled reports unavailable native execution; tests can fake it.
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '后台服务配置失败');
    }
  }

  Future<BackgroundRuntimeState?> status() async {
    if (!_supported) return null;
    try {
      final value = await channel.invokeMapMethod<String, dynamic>('status');
      if (value == null || value['enabled'] is! bool) return null;
      final state = BackgroundRuntimeState.fromMap(value);
      _enabled = state.enabled;
      failureReason = state.reason;
      failureMessage = state.message;
      return state;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> exitApplication() async {
    if (!_desktop && defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final requested = await channel.invokeMethod<bool>('exitApplication');
      // The native host rechecks visibility: a foreground app must survive
      // a resume that races with a background expiry.
      if (requested != true && requested != false) {
        throw const ApiFailure('定时退出失败，请手动关闭应用');
      }
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '定时退出失败，请手动关闭应用');
    } on MissingPluginException {
      throw const ApiFailure('定时退出失败，请手动关闭应用');
    }
  }

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
      await channel.invokeMethod<bool>('setEnabled', {
        ..._arguments,
        'enabled': enabled,
      }) ==
      true;

  Future<bool> _setEnabled(bool enabled) async {
    if (_desktop) {
      _enabled = enabled;
      return true;
    }
    if (!_supported) return !enabled;
    var nativeStartAttempted = false;
    try {
      if (!enabled) {
        final stopped = await _native(false);
        if (stopped) _enabled = false;
        return stopped;
      }
      if (_deadline != null && !_deadline!.isAfter(DateTime.now())) {
        await _native(false);
        _enabled = false;
        failureReason = 'deadline';
        return false;
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
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
          failureReason = 'permission';
          return false;
        }
      } else if (_mode == BackgroundServiceMode.location) {
        final states = await const AppPermissions(
          locationRequired: true,
        ).check();
        if (!states.any(
          (state) =>
              state.permission == AppPermission.location &&
              state.status == PermissionStatus.granted,
        )) {
          _enabled = false;
          failureReason = 'locationPermission';
          return false;
        }
      }
      failureReason = null;
      failureMessage = null;
      nativeStartAttempted = true;
      _enabled = await _native(true);
      if (!_enabled) {
        await _readStartFailure();
        _enabled = false;
      }
      return _enabled;
    } on Exception catch (error) {
      // Native callbacks may arrive while the controller is transitioning.
      // Read the reason before cleanup changes native status to "stopped".
      final observed = enabled && nativeStartAttempted
          ? await _readStartFailure()
          : null;
      final reason =
          observed?.reason ??
          (failureReason != 'stopped' ? failureReason : null) ??
          (error is PlatformException ? error.code : 'startFailed');
      final message =
          observed?.message ??
          failureMessage ??
          (error is PlatformException ? error.message : null);
      try {
        await _native(false);
      } on Exception {
        // Cleanup must not hide a failed start.
      }
      _enabled = false;
      failureReason = reason;
      failureMessage = message;
      return false;
    }
  }

  Future<BackgroundRuntimeState?> _readStartFailure() async {
    final previousReason = failureReason;
    final previousMessage = failureMessage;
    BackgroundRuntimeState? observed;
    try {
      // Keep this read separate from status(): a timed-out status future must
      // not later overwrite disabled state after the cleanup request returns.
      final raw = await channel
          .invokeMapMethod<String, dynamic>('status')
          .timeout(const Duration(seconds: 3));
      if (raw != null && raw['enabled'] is bool) {
        observed = BackgroundRuntimeState.fromMap(raw);
      }
    } catch (_) {
      // A missing diagnostic status must not hide the original start failure.
    }
    if (observed?.reason == null || observed?.reason == 'stopped') {
      failureReason = previousReason;
      failureMessage = previousMessage;
      return null;
    }
    failureReason = observed!.reason;
    failureMessage = observed.message;
    return observed;
  }
}
