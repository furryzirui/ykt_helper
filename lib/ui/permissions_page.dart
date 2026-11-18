import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/app_permissions.dart';
import 'settings_widgets.dart';

String _permissionName(AppPermission permission) => switch (permission) {
  AppPermission.camera => '相机',
  AppPermission.notifications => '通知',
  AppPermission.photos => '保存到相册',
  AppPermission.battery => '电池优化',
  AppPermission.autostart => '自启动',
  AppPermission.location => '定位',
};

IconData _permissionIcon(AppPermission permission) => switch (permission) {
  AppPermission.camera => Icons.photo_camera_outlined,
  AppPermission.notifications => Icons.notifications_outlined,
  AppPermission.photos => Icons.photo_library_outlined,
  AppPermission.battery => Icons.battery_saver_outlined,
  AppPermission.autostart => Icons.restart_alt_rounded,
  AppPermission.location => Icons.location_on_outlined,
};

String _statusText(AppPermission permission, PermissionStatus status) =>
    switch (status) {
      PermissionStatus.granted =>
        permission == AppPermission.battery ? '已取消优化' : '已允许',
      PermissionStatus.denied =>
        permission == AppPermission.battery ? '仍受优化' : '未允许',
      PermissionStatus.notRequired => '无需授权',
      PermissionStatus.unsupported => '暂不支持',
      PermissionStatus.needsConfirmation =>
        defaultTargetPlatform == TargetPlatform.windows &&
                permission == AppPermission.autostart
            ? '状态未知，可开启自启动'
            : '需在系统设置中确认',
    };

String _permissionExplanation(AppPermission permission, bool request) {
  if (permission == AppPermission.autostart) {
    return defaultTargetPlatform == TargetPlatform.windows
        ? request
              ? '用于登录 Windows 后在后台启动自动化。\n\n确认后，应用会为当前用户添加 ykt_helper 启动项，无需管理员权限。若已被系统禁用，将打开“启动应用”，请找到 ykt_helper 并允许启动。\n\n开启自启动需在自动化中打开“应用自启动”；设置会自动保存，已保存的开启设置在重新授权后恢复。'
              : '用于登录 Windows 后在后台启动自动化。\n\n将打开系统“启动应用”，可管理 ykt_helper 的启动权限。应用内“应用自启动”开关另行决定是否在登录后运行。'
        : '用于开机后和系统允许的进程回收后恢复自动化。\n\n将尝试打开系统自启动管理，请找到 ykt_helper 并允许自启动、关联启动或后台启动；若打开的是应用详情，请进入“自启动”或“权限”设置。请同时允许通知并取消电池优化。\n\nAndroid 无法统一读取厂商的自启动授权状态，设置后返回应用即可；强行停止后无法自动恢复。';
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return switch (permission) {
      AppPermission.camera => '用于扫描课堂二维码。\n\n确认后请求相机权限；若已拒绝，将打开本应用设置，请允许相机后返回。',
      AppPermission.notifications =>
        '用于显示应用通知。\n\n确认后请求通知权限；若已拒绝，将打开本应用设置，请允许通知后返回。',
      AppPermission.photos =>
        '用于将课件图片写入系统相册，无需读取你的照片。\n\n确认后申请添加照片权限；若已拒绝，将打开本应用设置，请允许添加照片后返回。',
      AppPermission.battery => 'iOS 不提供本应用的电池优化豁免设置。',
      AppPermission.autostart => 'iOS 暂不支持应用自启动。',
      AppPermission.location =>
        '仅用于持续定位保活，尝试在锁屏或切换应用后运行自动化，可能明显增加耗电并显示定位指示。定位数据不会上传，也不用于课堂签到。\n\n请先允许使用定位；系统提供“始终允许”时请选择该项。若没有出现该选项，请到本应用设置 → 定位 → 始终，或等待系统后续询问。授权后返回应用。',
    };
  }
  if (!request) {
    return switch (permission) {
      AppPermission.camera => '用于扫描课堂二维码。\n\n将打开本应用详情，请进入“权限”管理相机授权。',
      AppPermission.notifications =>
        '用于显示后台课堂运行通知。\n\n将打开本应用通知设置，可管理通知开关及后台课堂通知类别。',
      AppPermission.photos => '用于将课件图片保存到系统相册。\n\n将打开本应用详情，请进入“权限”管理存储授权。',
      AppPermission.battery => _batteryExplanation,
      AppPermission.autostart => '',
      AppPermission.location => '当前平台无需定位授权。',
    };
  }
  return switch (permission) {
    AppPermission.camera =>
      '用于扫描课堂二维码。\n\n请在系统弹窗中允许使用相机；若系统无法再次弹出授权，将打开本应用设置，请进入“权限”允许相机。',
    AppPermission.notifications =>
      '用于显示后台课堂运行通知。\n\n请在系统弹窗中允许通知；若当前系统不支持弹窗、已拒绝再次询问或后台通知类别被关闭，将打开通知设置，请允许本应用及后台课堂通知类别。',
    AppPermission.photos =>
      '用于将课件图片保存到系统相册。\n\n请在系统弹窗中允许存储；无法弹出时进入本应用设置的“权限”，允许存储后返回重试。',
    AppPermission.battery => _batteryExplanation,
    AppPermission.autostart => '',
    AppPermission.location => '当前平台无需定位授权。',
  };
}

const _batteryExplanation =
    '用于减少锁屏时课堂连接被系统暂停。\n\n将打开本应用详情，请进入“电池”或“耗电管理”，允许后台运行并取消电池优化。不同系统的选项名称可能不同，设置完成后返回应用。';

Future<bool> showPermissionSettingsExplanation(
  BuildContext context,
  AppPermission permission, {
  bool request = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_permissionName(permission)),
        content: SingleChildScrollView(
          child: Text(_permissionExplanation(permission, request)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(request ? '继续授权' : '前往设置'),
          ),
        ],
      ),
    ) ??
    false;

void _permissionError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> ensureAppPermission(
  BuildContext context,
  AppPermission permission, {
  AppPermissions permissions = const AppPermissions(),
}) async {
  PermissionStatus status;
  try {
    final states = await permissions.check();
    status = states
        .singleWhere((state) => state.permission == permission)
        .status;
  } catch (_) {
    if (context.mounted) _permissionError(context, '无法读取应用权限，请重试');
    return false;
  }
  if (!context.mounted) return false;
  switch (status) {
    case PermissionStatus.granted:
    case PermissionStatus.notRequired:
      return true;
    case PermissionStatus.unsupported:
      _permissionError(context, '当前平台暂不支持此权限功能');
      return false;
    case PermissionStatus.needsConfirmation:
      final prepareWindowsStartup =
          defaultTargetPlatform == TargetPlatform.windows &&
          permission == AppPermission.autostart;
      final requestIosLocation =
          defaultTargetPlatform == TargetPlatform.iOS &&
          permission == AppPermission.location;
      if (!await showPermissionSettingsExplanation(
        context,
        permission,
        request: prepareWindowsStartup || requestIosLocation,
      )) {
        return false;
      }
      if (!context.mounted) return false;
      try {
        if (prepareWindowsStartup || requestIosLocation) {
          if (!await permissions.request(permission)) return false;
          final states = await permissions.check();
          return states
                  .singleWhere((item) => item.permission == permission)
                  .status ==
              PermissionStatus.granted;
        }
        await permissions.openSettings(permission);
      } catch (_) {
        if (context.mounted) {
          _permissionError(
            context,
            requestIosLocation ? '无法申请定位权限，请在系统设置中检查定位授权' : '无法打开系统设置，请手动检查自启动',
          );
        }
      }
      return false;
    case PermissionStatus.denied:
      if (!await showPermissionSettingsExplanation(
        context,
        permission,
        request: true,
      )) {
        return false;
      }
      if (!context.mounted) return false;
      try {
        final granted = await permissions.request(permission);
        if (!granted) return false;
        final states = await permissions.check();
        final latest = states
            .singleWhere((state) => state.permission == permission)
            .status;
        return latest == PermissionStatus.granted ||
            latest == PermissionStatus.notRequired;
      } catch (_) {
        if (context.mounted) {
          _permissionError(context, '无法申请权限，请在应用权限中重试');
        }
      }
      return false;
  }
}

class PermissionsPage extends StatefulWidget {
  final AppPermissions permissions;
  final bool locationRequired;
  const PermissionsPage({
    super.key,
    this.permissions = const AppPermissions(),
    this.locationRequired = false,
  });

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with WidgetsBindingObserver {
  Map<AppPermission, PermissionStatus>? _states;
  String? _error;
  bool _checking = false, _opening = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final states = await widget.permissions.check();
      final result = {
        for (final state in states) state.permission: state.status,
      };
      if (defaultTargetPlatform != TargetPlatform.iOS ||
          !widget.locationRequired) {
        result[AppPermission.location] = PermissionStatus.notRequired;
      }
      if (result.length != AppPermission.values.length ||
          states.length != AppPermission.values.length) {
        throw StateError('Incomplete permission states');
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _states = result;
        _checking = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _states = null;
        _checking = false;
        _error = '无法读取应用权限，请重试';
      });
    }
  }

  Future<void> _manage(AppPermission permission) async {
    if (_opening || _checking) return;
    setState(() => _opening = true);
    try {
      final request =
          _states?[permission] == PermissionStatus.denied ||
          defaultTargetPlatform == TargetPlatform.iOS &&
              permission == AppPermission.location &&
              _states?[permission] == PermissionStatus.needsConfirmation ||
          defaultTargetPlatform == TargetPlatform.windows &&
              permission == AppPermission.autostart &&
              _states?[permission] == PermissionStatus.needsConfirmation;
      if (!await showPermissionSettingsExplanation(
        context,
        permission,
        request: request,
      )) {
        return;
      }
      if (!mounted) return;
      if (request) {
        await widget.permissions.request(permission);
        if (mounted) await _refresh();
      } else {
        await widget.permissions.openSettings(permission);
      }
    } catch (_) {
      if (mounted) {
        _permissionError(context, '无法打开系统设置，请在系统设置中找到本应用后调整权限');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final states = _states;
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用权限'),
        actions: [
          IconButton(
            tooltip: '刷新权限状态',
            onPressed: _checking ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _refresh,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : states == null
          ? const Center(child: CircularProgressIndicator())
          : SettingsList(
              children: [
                for (final permission in AppPermission.values)
                  Card(
                    child: ListTile(
                      minVerticalPadding: 14,
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _permissionIcon(permission),
                          color: scheme.primary,
                          size: 22,
                        ),
                      ),
                      title: Text(_permissionName(permission)),
                      subtitle: Text(
                        _statusText(permission, states[permission]!),
                        style: TextStyle(
                          color: states[permission] == PermissionStatus.denied
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      trailing:
                          states[permission] == PermissionStatus.notRequired ||
                              states[permission] == PermissionStatus.unsupported
                          ? null
                          : const Icon(Icons.chevron_right_rounded),
                      onTap:
                          _checking ||
                              _opening ||
                              states[permission] ==
                                  PermissionStatus.notRequired ||
                              states[permission] == PermissionStatus.unsupported
                          ? null
                          : () => _manage(permission),
                    ),
                  ),
              ],
            ),
    );
  }
}
