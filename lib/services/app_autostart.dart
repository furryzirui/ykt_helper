import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';

/// Native registration contains only flags, never credentials or AI settings.
class AppAutostart {
  static const channel = MethodChannel('ykt_helper/app_autostart');
  const AppAutostart();
  static FutureOr<void> Function()? _foregroundListener;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// Registers a visible Windows startup item only after explicit UI consent.
  /// This prepares authorization; configure() separately enables actual work.
  Future<void> prepare() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      throw const ApiFailure('当前平台不支持此自启动授权方式');
    }
    try {
      await channel.invokeMethod<void>('prepare');
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法添加 Windows 启动项');
    } on MissingPluginException {
      throw const ApiFailure('当前平台无法配置应用自启动');
    }
  }

  /// Called after saved settings or login state changes. Never requests a
  /// permission, shows a window or launches the service itself.
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('configure', {
        'enabled': enabled,
        'eligible': eligible,
      });
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法保存应用自启动设置');
    } on MissingPluginException {
      throw const ApiFailure('当前平台无法配置应用自启动');
    }
  }

  /// Explicit service-off wins over later boot/process-recovery events.
  Future<void> setSuspended(bool suspended) async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('setSuspended', {
        'suspended': suspended,
      });
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法保存服务暂停状态');
    } on MissingPluginException {
      throw const ApiFailure('当前平台无法配置应用自启动');
    }
  }

  Future<bool> enabled() async {
    if (!supported) return false;
    try {
      final state = await channel.invokeMapMethod<String, dynamic>('status');
      if (state?['enabled'] is! bool) throw const ApiFailure('无法读取应用自启动状态');
      return state!['enabled'] as bool;
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法读取应用自启动状态');
    } on MissingPluginException {
      throw const ApiFailure('当前平台无法读取应用自启动状态');
    }
  }

  /// Windows reads the StartupApps override. Unknown formats stay unverified
  /// in the permissions page; only explicit denial blocks its startup switch.
  Future<String> permissionStatus() async {
    if (!supported) return 'unsupported';
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'needsConfirmation';
    }
    try {
      final state = await channel.invokeMapMethod<String, dynamic>('status');
      final value = state?['permission'];
      if (value != 'granted' &&
          value != 'denied' &&
          value != 'needsConfirmation') {
        throw const ApiFailure('无法读取应用自启动状态');
      }
      return value as String;
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '无法读取应用自启动状态');
    } on MissingPluginException {
      throw const ApiFailure('当前平台无法读取应用自启动状态');
    }
  }

  /// A background engine delays dialogs until a real Activity/window appears.
  static void setForegroundListener(FutureOr<void> Function()? listener) {
    _foregroundListener = listener;
    channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method == 'foreground') await listener();
            },
    );
    if (listener != null && const AppAutostart().supported) {
      unawaited(_checkForeground(listener));
    }
  }

  static Future<void> _checkForeground(
    FutureOr<void> Function() listener,
  ) async {
    try {
      final foreground = await channel.invokeMethod<bool>('isForeground');
      if (foreground == true && identical(listener, _foregroundListener)) {
        await listener();
      }
    } on MissingPluginException {
      // No supported native bridge in a test or non-native host.
    } on PlatformException {
      // A later native foreground event still invokes the registered listener.
    }
  }
}
