import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../services/app_permissions.dart';
import '../domain/models.dart';
import 'about_page.dart';
import 'automation_page.dart';
import 'background_service_confirmation.dart';
import 'login_page.dart';
import 'logs_page.dart';
import 'permissions_page.dart';
import 'service_timeout_picker.dart';
import 'settings_widgets.dart';

class SettingsPage extends StatefulWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _automationDraft = AutomationDraft();

  Future<void> _open(Widget page) =>
      Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));

  Widget _menu(
    IconData icon,
    String title,
    String description,
    VoidCallback? onTap,
  ) => Card(
    child: SettingTile(
      icon: icon,
      title: title,
      description: description,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      return SettingsList(
        children: [
          Card(
            child: SettingTile(
              icon: Icons.person_outline_rounded,
              title: c.account?.name ?? '未登录',
              description: c.account == null
                  ? '登录后查看课程与课堂'
                  : c.account!.school.isEmpty
                  ? '已登录'
                  : c.account!.school,
              trailing: c.account == null
                  ? FilledButton(
                      onPressed: !c.initialized
                          ? null
                          : () => _open(LoginPage(controller: c)),
                      child: Text(c.initialized ? '登录' : '初始化中…'),
                    )
                  : OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () async {
                              try {
                                await c.logout();
                                _automationDraft.clear();
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('退出登录失败，请重试')),
                                  );
                                }
                              }
                            },
                      child: const Text('退出登录'),
                    ),
            ),
          ),
          Card(
            child: Column(
              children: [
                SettingTile(
                  icon: Icons.power_settings_new_rounded,
                  title: '系统服务',
                  description: '保持自动化后台运行，关闭后仅前台运行，可减少耗电',
                  trailing: !c.systemServiceSupported
                      ? Icon(
                          defaultTargetPlatform == TargetPlatform.windows
                              ? Icons.check_circle_outline_rounded
                              : Icons.info_outline_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : Switch(
                          value: c.backgroundEnabled,
                          onChanged:
                              !c.initialized ||
                                  c.backgroundBusy ||
                                  !c.systemServiceSupported ||
                                  c.account == null && !c.backgroundEnabled ||
                                  !(c.settings.autoEnter ||
                                      c.settings.autoAnswer)
                              ? null
                              : (enabled) async {
                                  try {
                                    final ios =
                                        defaultTargetPlatform ==
                                        TargetPlatform.iOS;
                                    if (enabled && ios) {
                                      final mode = c.settings.backgroundMode;
                                      if (mode ==
                                              BackgroundServiceMode
                                                  .continuedTask &&
                                          c.settings.serviceTimeoutMinutes ==
                                              0) {
                                        final minutes =
                                            await selectServiceTimeout(
                                              context,
                                              selected: c
                                                  .settings
                                                  .serviceTimeoutMinutes,
                                              allowNever: false,
                                            );
                                        if (minutes == null ||
                                            !context.mounted) {
                                          return;
                                        }
                                        await c.setServiceTimeout(minutes);
                                        if (!context.mounted) return;
                                      }
                                      if (!await confirmIosBackgroundService(
                                        context,
                                        mode,
                                      )) {
                                        return;
                                      }
                                      if (!context.mounted) return;
                                      if (c.settings.backgroundMode != mode) {
                                        return;
                                      }
                                      if (mode ==
                                              BackgroundServiceMode.location &&
                                          !await ensureAppPermission(
                                            context,
                                            AppPermission.location,
                                            permissions: const AppPermissions(
                                              locationRequired: true,
                                            ),
                                          )) {
                                        return;
                                      }
                                    }
                                    await c.setSystemService(
                                      enabled,
                                      iosConfirmed: enabled && ios,
                                    );
                                  } catch (error) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            error is ApiFailure
                                                ? error.message
                                                : '系统服务切换失败，请重试',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                        ),
                ),
                if (c.backgroundWarning != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      c.backgroundWarning!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (c.backgroundEnabled ||
                    defaultTargetPlatform == TargetPlatform.windows) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _ServiceTimeoutTile(controller: c),
                ],
              ],
            ),
          ),
          _menu(Icons.shield_outlined, '应用权限', '查看授权状态与系统权限设置', () async {
            await _open(
              PermissionsPage(
                permissions: AppPermissions(
                  locationRequired:
                      c.settings.backgroundMode ==
                      BackgroundServiceMode.location,
                ),
                locationRequired:
                    c.settings.backgroundMode == BackgroundServiceMode.location,
              ),
            );
            if (!context.mounted) return;
            try {
              await c.retryBackground();
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('后台运行检查失败，请重试')));
              }
            }
          }),
          _menu(
            Icons.auto_awesome_outlined,
            '自动化',
            '自动签到、答题与服务启动设置',
            !c.initialized
                ? null
                : () => _open(
                    AutomationPage(controller: c, draft: _automationDraft),
                  ),
          ),
          _menu(
            Icons.receipt_long_outlined,
            '应用日志',
            '查看运行记录或导出文档',
            () => _open(LogsPage(controller: c)),
          ),
          _menu(
            Icons.info_outline_rounded,
            '关于',
            '应用版本、开发者与开源信息',
            () => _open(const AboutPage()),
          ),
        ],
      );
    },
  );
}

class _ServiceTimeoutTile extends StatefulWidget {
  final AppController controller;
  const _ServiceTimeoutTile({required this.controller});

  @override
  State<_ServiceTimeoutTile> createState() => _ServiceTimeoutTileState();
}

class _ServiceTimeoutTileState extends State<_ServiceTimeoutTile> {
  Timer? _ticker;
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.serviceDeadline != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _remaining {
    final remaining = widget.controller.serviceRemaining;
    if (remaining == null) return '永不';
    final seconds = remaining.inSeconds.clamp(0, 86400);
    final hours = seconds ~/ 3600;
    final minutes = seconds % 3600 ~/ 60;
    final tail = (seconds % 60).toString().padLeft(2, '0');
    return hours > 0
        ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$tail'
        : '${minutes.toString().padLeft(2, '0')}:$tail';
  }

  Future<void> _select() async {
    if (_selecting) return;
    setState(() => _selecting = true);
    final controller = widget.controller;
    try {
      final choice = await selectServiceTimeout(
        context,
        selected: controller.settings.serviceTimeoutMinutes,
        allowNever:
            defaultTargetPlatform != TargetPlatform.iOS ||
            controller.settings.backgroundMode !=
                BackgroundServiceMode.continuedTask,
      );
      if (choice != null) await controller.setServiceTimeout(choice);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error is ApiFailure ? error.message : '定时关闭设置失败，请重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingTile(
    key: const ValueKey('service-timeout'),
    icon: Icons.timer_outlined,
    title: '定时关闭',
    description: defaultTargetPlatform == TargetPlatform.windows
        ? '到时若在后台则退出应用'
        : defaultTargetPlatform == TargetPlatform.iOS
        ? '到时关闭后台服务'
        : '到时关闭服务，后台时结束运行',
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_remaining, key: const ValueKey('service-countdown')),
        const SizedBox(width: 4),
        const Icon(Icons.expand_more_rounded),
      ],
    ),
    onTap: _selecting || widget.controller.backgroundBusy ? null : _select,
  );
}
