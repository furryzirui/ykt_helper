import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../domain/app_info.dart';
import '../ui/startup_notices.dart';
import 'integrity_service.dart';

const githubReleasesUrl =
    'https://github.com/furryzirui/ykt_helper/releases/latest';

/// A release that is newer than the version running on this device.
class UpdateInfo {
  final String version;
  final Uri url;
  const UpdateInfo({required this.version, required this.url});
}

/// Compares numeric semantic versions, ignoring a leading `v` and build data.
/// Invalid values return null so a malformed remote response is ignored.
List<int>? parseVersion(String value) {
  final match = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}

int compareVersions(String left, String right) {
  final a = parseVersion(left);
  final b = parseVersion(right);
  if (a == null || b == null) return 0;
  for (var index = 0; index < 3; index++) {
    final comparison = a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

typedef ReleaseFetcher = Future<Map<String, dynamic>?> Function();

/// Read-only checker for the single trusted public repository.
class UpdateService {
  final String currentVersion;
  final Dio _client;
  final ReleaseFetcher? _fetcher;

  UpdateService({String? currentVersion, Dio? client, ReleaseFetcher? fetcher})
    : currentVersion = currentVersion ?? AppInfo.version,
      _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 4),
              sendTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 5),
              followRedirects: false,
              validateStatus: (status) => status == 200,
            ),
          ),
      _fetcher = fetcher;

  static final Uri endpoint = Uri.parse(
    'https://api.github.com/repos/furryzirui/ykt_helper/releases/latest',
  );

  Future<UpdateInfo?> check() async {
    try {
      final data = _fetcher != null ? await _fetcher() : await _getLatest();
      if (data == null ||
          (data['draft'] != null && data['draft'] is! bool) ||
          (data['prerelease'] != null && data['prerelease'] is! bool) ||
          data['draft'] == true ||
          data['prerelease'] == true) {
        return null;
      }
      final tag = data['tag_name'];
      if (tag is! String) return null;
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      // A tag can be marked stable incorrectly in a malformed API response;
      // reject prerelease suffixes independently of the boolean flag.
      if (version.contains('-') ||
          parseVersion(version) == null ||
          compareVersions(version, currentVersion) <= 0) {
        return null;
      }
      // The API response is untrusted. Always guide users to this fixed URL;
      // never open a URL supplied by a release body or a compromised mirror.
      return UpdateInfo(version: version, url: Uri.parse(githubReleasesUrl));
    } catch (_) {
      // Startup checks are best effort and must never block app launch.
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getLatest() async {
    final response = await _client.getUri<Map<String, dynamic>>(endpoint);
    if (response.statusCode != 200 || response.data == null) return null;
    return response.data;
  }
}

typedef IntegrityChecker = Future<IntegrityResult> Function();

/// Runs the integrity and update checks once after the first frame.
/// Dialog presentation lives in [StartupNotices] so this coordinator is easy
/// to exercise without making network requests in widget tests.
class StartupChecks extends StatefulWidget {
  final Widget child;
  final Future<UpdateInfo?> Function()? updateCheck;
  final IntegrityChecker? integrityCheck;
  final bool enabled;

  const StartupChecks({
    super.key,
    required this.child,
    this.updateCheck,
    this.integrityCheck,
    this.enabled = true,
  });

  @override
  State<StartupChecks> createState() => _StartupChecksState();
}

class _StartupChecksState extends State<StartupChecks> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  Future<void> _run() async {
    if (_started || !widget.enabled) return;
    _started = true;
    IntegrityResult result;
    try {
      result =
          await (widget.integrityCheck?.call() ?? IntegrityService().check());
    } catch (_) {
      result = const IntegrityResult(verified: false, detail: '完整性检查未能完成');
    }
    if (!mounted) return;
    await StartupNotices.showIntegrityWarning(context, result);
    if (!mounted) return;
    UpdateInfo? update;
    try {
      update = await (widget.updateCheck?.call() ?? UpdateService().check());
    } catch (_) {
      // A custom checker must have the same silent-failure behavior as the
      // network-backed default service.
      update = null;
    }
    if (!mounted || update == null) return;
    await StartupNotices.showUpdate(context, update);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
