import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/app_info.dart';
import 'widgets.dart';

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
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            leading: TintedIcon(Icons.menu_book_rounded),
            title: Text(AppInfo.name),
          ),
        ),
        const Card(
          child: ListTile(
            leading: TintedIcon(Icons.person_outline_rounded),
            title: Text('开发者'),
            subtitle: Text(AppInfo.developer),
          ),
        ),
        Card(
          child: ListTile(
            leading: const TintedIcon(Icons.code_rounded),
            title: const Text('开源仓库'),
            subtitle: const Text(AppInfo.repositoryUrl),
            trailing: const Icon(Icons.open_in_new_rounded),
            onTap: () => _openRepository(context),
          ),
        ),
        const Card(
          child: ListTile(
            leading: TintedIcon(Icons.description_outlined),
            title: Text('开源许可'),
            subtitle: Text(AppInfo.license),
          ),
        ),
      ],
    ),
  );
}
