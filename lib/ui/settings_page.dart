import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'about_page.dart';
import 'automation_page.dart';
import 'login_page.dart';
import 'logs_page.dart';
import 'permissions_page.dart';
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
            child: SettingTile(
              icon: Icons.power_settings_new_rounded,
              title: '系统服务',
              description: !c.systemServiceSupported
                  ? '当前平台无需系统服务'
                  : c.account == null
                  ? '登录并启用自动化后可开启'
                  : !(c.settings.autoEnter || c.settings.autoAnswer)
                  ? '启用自动化后可开启，后台运行会增加耗电'
                  : c.backgroundWarning ?? '保持自动化后台运行，关闭可减少耗电',
              trailing: Switch(
                value: c.backgroundEnabled,
                onChanged:
                    !c.initialized ||
                        c.backgroundBusy ||
                        !c.systemServiceSupported ||
                        c.account == null ||
                        !(c.settings.autoEnter || c.settings.autoAnswer)
                    ? null
                    : (enabled) async {
                        try {
                          await c.setSystemService(enabled);
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('系统服务切换失败，请重试')),
                            );
                          }
                        }
                      },
              ),
            ),
          ),
          _menu(Icons.shield_outlined, '应用权限', '查看授权状态与系统权限设置', () async {
            await _open(const PermissionsPage());
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
