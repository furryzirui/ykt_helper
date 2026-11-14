import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'about_page.dart';
import 'automation_page.dart';
import 'login_page.dart';
import 'logs_page.dart';
import 'permissions_page.dart';
import 'widgets.dart';

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

  Widget _menu(IconData icon, String title, VoidCallback? onTap) => Card(
    child: ListTile(
      minVerticalPadding: 14,
      leading: TintedIcon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              minVerticalPadding: 14,
              leading: const TintedIcon(Icons.person_outline_rounded),
              title: Text(c.account?.name ?? '未登录'),
              subtitle: c.account == null ? null : Text(c.account!.school),
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
          const SizedBox(height: 8),
          _menu(Icons.shield_outlined, '应用权限', () async {
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
            !c.initialized
                ? null
                : () => _open(
                    AutomationPage(controller: c, draft: _automationDraft),
                  ),
          ),
          _menu(
            Icons.receipt_long_outlined,
            '应用日志',
            () => _open(LogsPage(controller: c)),
          ),
          const SizedBox(height: 8),
          _menu(
            Icons.info_outline_rounded,
            '关于',
            () => _open(const AboutPage()),
          ),
        ],
      );
    },
  );
}
