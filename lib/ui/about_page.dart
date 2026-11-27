import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/app_info.dart';
import 'settings_widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _openRepository(BuildContext context) async {
    try {
      if (!await launchUrl(
        Uri.parse(AppInfo.repositoryUrl),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('Browser unavailable');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，请稍后重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关于')),
    body: SettingsList(
      children: [
        const Card(
          child: SettingTile(
            icon: Icons.menu_book_rounded,
            title: AppInfo.name,
            description: '版本 ${AppInfo.version}（build ${AppInfo.buildNumber}）',
          ),
        ),
        const Card(
          child: SettingTile(
            icon: Icons.person_outline_rounded,
            title: '开发者',
            description: AppInfo.developer,
          ),
        ),
        Card(
          child: SettingTile(
            icon: Icons.code_rounded,
            title: '开源仓库',
            description: 'github.com/furryzirui/ykt_helper',
            trailing: const Icon(Icons.open_in_new_rounded),
            onTap: () => _openRepository(context),
          ),
        ),
        const Card(
          child: SettingTile(
            icon: Icons.description_outlined,
            title: '开源许可',
            description: AppInfo.license,
          ),
        ),
      ],
    ),
  );
}
