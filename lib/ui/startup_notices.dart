import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/integrity_service.dart';
import '../services/startup_checks.dart';

/// Small, text-only startup notices. Failures opening the browser are caught
/// because a broken external handler must not interrupt app startup.
class StartupNotices {
  static Future<void> showIntegrityWarning(
    BuildContext context,
    IntegrityResult result,
  ) async {
    if (result.verified || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('风险提示'),
        content: Text(
          result.detail == null || result.detail!.trim().isEmpty
              ? '无法确认应用来自官方发布，文件可能已被修改。建议前往 GitHub 下载。'
              : '${result.detail}\n\n建议前往 GitHub 下载官方版本。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _openGitHub();
            },
            child: const Text('打开 GitHub'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('继续使用'),
          ),
        ],
      ),
    );
  }

  static Future<void> showUpdate(
    BuildContext context,
    UpdateInfo update,
  ) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 ${update.version}'),
        content: const Text('可以前往 GitHub 查看并下载最新版本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _openGitHub(_safeReleaseUrl(update.url));
            },
            child: const Text('打开 GitHub'),
          ),
        ],
      ),
    );
  }

  static Uri _safeReleaseUrl(Uri candidate) {
    final fixed = Uri.parse(githubReleasesUrl);
    if (candidate.scheme == 'https' &&
        candidate.host == fixed.host &&
        candidate.path == fixed.path &&
        candidate.userInfo.isEmpty &&
        candidate.query.isEmpty &&
        candidate.fragment.isEmpty) {
      return candidate;
    }
    return fixed;
  }

  static Future<void> _openGitHub([Uri? target]) async {
    try {
      await launchUrl(
        target ?? Uri.parse(githubReleasesUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // The browser may be unavailable on an emulator or restricted desktop.
    }
  }
}
