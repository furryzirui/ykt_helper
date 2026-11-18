import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';
import 'background_diagnostics.dart';

enum AppLogEvent {
  startup('启动'),
  login('登录'),
  logout('退出登录'),
  refresh('刷新课程与动态'),
  settings('保存自动化设置'),
  background('后台服务检查'),
  backgroundHeartbeat('Dart 执行心跳（测试）'),
  backgroundSnapshot('iOS 原生状态快照（测试）'),
  lessons('读取课堂列表'),
  detail('读取课堂详情'),
  attendance('读取签到状态'),
  enter('签到进入课堂'),
  scan('扫描课堂二维码'),
  connection('课堂连接状态变化'),
  classroomEvent('处理课堂事件'),
  answers('同步本人答案'),
  submit('提交答案'),
  automatic('自动作答'),
  draft('自动填充答案'),
  location('位置签到'),
  gallery('保存课件到相册'),
  export('导出课件'),
  api('雨课堂接口请求'),
  failure('应用异常');

  final String label;
  const AppLogEvent(this.label);
}

class AppLogEntry {
  final DateTime time;
  final AppLogEvent event;
  final bool? success;
  final int? code, count;
  final BackgroundServiceMode? backgroundMode;
  final bool? foreground;
  final IosBackgroundSnapshot? backgroundSnapshot;
  const AppLogEntry({
    required this.time,
    required this.event,
    this.success,
    this.code,
    this.count,
    this.backgroundMode,
    this.foreground,
    this.backgroundSnapshot,
  });

  bool get _diagnostic =>
      event == AppLogEvent.backgroundHeartbeat ||
      event == AppLogEvent.backgroundSnapshot;

  static String _modeLabel(BackgroundServiceMode mode) => switch (mode) {
    BackgroundServiceMode.native => '系统默认',
    BackgroundServiceMode.silentAudio => '静音音频',
    BackgroundServiceMode.pictureInPicture => '画中画',
    BackgroundServiceMode.location => '持续定位',
    BackgroundServiceMode.continuedTask => 'iOS 26 长任务',
  };

  static String _appStateLabel(BackgroundDiagnosticAppState state) =>
      switch (state) {
        BackgroundDiagnosticAppState.active => '前台',
        BackgroundDiagnosticAppState.inactive => '非活跃',
        BackgroundDiagnosticAppState.background => '后台',
      };

  String get message => [
    event.label,
    if (success != null)
      _diagnostic
          ? success!
                ? '已读取'
                : '不可用'
          : success!
          ? '成功'
          : '失败',
    if (code != null) '状态码 $code',
    if (count != null) '数量 $count',
    if (event == AppLogEvent.backgroundHeartbeat && backgroundMode != null)
      _modeLabel(backgroundMode!),
    if (event == AppLogEvent.backgroundHeartbeat && foreground != null)
      foreground! ? 'Dart 前台执行' : 'Dart 后台执行',
    if (event == AppLogEvent.backgroundSnapshot &&
        backgroundSnapshot != null) ...[
      '原生方案 ${_modeLabel(backgroundSnapshot!.mode)}',
      if (backgroundMode != null && backgroundMode != backgroundSnapshot!.mode)
        '配置方案 ${_modeLabel(backgroundMode!)}',
      backgroundSnapshot!.enabled ? '原生服务已启用' : '原生服务未启用',
      '原生${_appStateLabel(backgroundSnapshot!.appState)}',
      if (backgroundSnapshot!.audioPlaying != null)
        backgroundSnapshot!.audioPlaying! ? '音频播放中' : '音频未播放',
      if (backgroundSnapshot!.audioTimeMs != null)
        '音频位置 ${backgroundSnapshot!.audioTimeMs} ms',
      if (backgroundSnapshot!.pipActive != null)
        backgroundSnapshot!.pipActive! ? '画中画已激活' : '画中画未激活',
      if (backgroundSnapshot!.pipFrameCount != null)
        '画中画累计送帧 ${backgroundSnapshot!.pipFrameCount}',
    ],
    if (event == AppLogEvent.backgroundSnapshot &&
        backgroundSnapshot == null &&
        backgroundMode != null)
      '配置方案 ${_modeLabel(backgroundMode!)}',
  ].join(' · ');

  Map<String, Object?> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'event': event.name,
    if (success != null) 'success': success,
    if (code != null) 'code': code,
    if (count != null) 'count': count,
    if (_diagnostic && backgroundMode != null)
      'backgroundMode': backgroundMode!.name,
    if (event == AppLogEvent.backgroundHeartbeat && foreground != null)
      'foreground': foreground,
    if (event == AppLogEvent.backgroundSnapshot && backgroundSnapshot != null)
      'backgroundSnapshot': backgroundSnapshot!.toJson(),
  };

  static AppLogEntry? parse(Object? raw) {
    if (raw is! Map) return null;
    final event = AppLogEvent.values
        .where((event) => event.name == raw['event'])
        .firstOrNull;
    final time = DateTime.tryParse(raw['time'] is String ? raw['time'] : '');
    if (event == null || time == null) return null;
    return AppLogEntry(
      event: event,
      time: time.toLocal(),
      success: raw['success'] is bool ? raw['success'] : null,
      code: raw['code'] is int ? raw['code'] : null,
      count: raw['count'] is int ? raw['count'] : null,
      backgroundMode:
          event == AppLogEvent.backgroundHeartbeat ||
              event == AppLogEvent.backgroundSnapshot
          ? BackgroundServiceMode.values
                .where((mode) => mode.name == raw['backgroundMode'])
                .firstOrNull
          : null,
      foreground:
          event == AppLogEvent.backgroundHeartbeat && raw['foreground'] is bool
          ? raw['foreground'] as bool
          : null,
      backgroundSnapshot: event == AppLogEvent.backgroundSnapshot
          ? IosBackgroundSnapshot.parse(raw['backgroundSnapshot'])
          : null,
    );
  }
}

/// A bounded local event log. Only enum labels, booleans and numeric results are accepted:
/// headers, URLs, cookies, keys, account data, questions and answers cannot enter
/// the log through this API. Imported entries are rebuilt from the same schema.
class AppLogs extends ChangeNotifier {
  static const maxEntries = 500;
  final Future<File> Function()? fileProvider;
  final List<AppLogEntry> _entries = [];
  File? _file;
  Future<void> _writes = Future.value();
  Future<void>? _initializing;
  bool _disposed = false;
  bool storageUnavailable = false;
  final bool iosBackgroundDiagnostics;
  AppLogs({
    this.fileProvider,
    this.iosBackgroundDiagnostics = iosBackgroundDiagnosticsEnabled,
  });

  List<AppLogEntry> get entries => List.unmodifiable(_entries.reversed);

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      final file = await (fileProvider?.call() ?? _defaultFile());
      final saved = <AppLogEntry>[];
      if (await file.exists()) {
        // Avoid reading an accidentally oversized or replaced file into memory.
        if (await file.length() <= 1024 * 1024) {
          for (final line in await file.readAsLines()) {
            try {
              final entry = AppLogEntry.parse(jsonDecode(line));
              if (entry != null &&
                  (iosBackgroundDiagnostics || !entry._diagnostic)) {
                saved.add(entry);
              }
            } catch (_) {
              // One incomplete line must not discard the other events.
            }
          }
        }
      }
      if (_disposed) return;
      _entries.insertAll(0, saved);
      _trim();
      _file = file;
      _persist();
    } catch (_) {
      storageUnavailable = true;
    }
    if (!_disposed) notifyListeners();
  }

  static Future<File> _defaultFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/app-logs/events.jsonl');
  }

  void add(AppLogEvent event, {bool? success, int? code, int? count}) {
    if (_disposed ||
        !iosBackgroundDiagnostics &&
            (event == AppLogEvent.backgroundHeartbeat ||
                event == AppLogEvent.backgroundSnapshot)) {
      return;
    }
    _entries.add(
      AppLogEntry(
        time: DateTime.now(),
        event: event,
        success: success,
        code: code,
        count: count,
      ),
    );
    _trim();
    _persist();
    notifyListeners();
  }

  void addBackgroundHeartbeat({
    required BackgroundServiceMode mode,
    required bool foreground,
  }) {
    if (_disposed || !iosBackgroundDiagnostics) return;
    _entries.add(
      AppLogEntry(
        time: DateTime.now(),
        event: AppLogEvent.backgroundHeartbeat,
        backgroundMode: mode,
        foreground: foreground,
      ),
    );
    _trim();
    _persist();
    notifyListeners();
  }

  void addBackgroundSnapshot({
    required BackgroundServiceMode mode,
    required IosBackgroundSnapshot? snapshot,
  }) {
    if (_disposed || !iosBackgroundDiagnostics) return;
    _entries.add(
      AppLogEntry(
        time: DateTime.now(),
        event: AppLogEvent.backgroundSnapshot,
        success: snapshot != null,
        backgroundMode: mode,
        backgroundSnapshot: snapshot,
      ),
    );
    _trim();
    _persist();
    notifyListeners();
  }

  void _trim() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  void _persist() {
    final file = _file;
    if (file == null) return;
    final content = _entries
        .map((entry) => jsonEncode(entry.toJson()))
        .join('\n');
    _writes = _writes
        .then((_) async {
          final temporary = File('${file.path}.tmp');
          await file.parent.create(recursive: true);
          await temporary.writeAsString(content, flush: true);
          if (Platform.isWindows && await file.exists()) await file.delete();
          await temporary.rename(file.path);
          if (storageUnavailable && !_disposed) {
            storageUnavailable = false;
            notifyListeners();
          }
        })
        .catchError((Object _) {
          if (!_disposed && !storageUnavailable) {
            storageUnavailable = true;
            notifyListeners();
          }
        });
  }

  Future<void> flush() => _writes;

  String document() => [
    'ykt_helper 应用日志',
    '导出时间：${DateTime.now().toLocal().toIso8601String()}',
    '仅记录操作类型和结果，不包含账号、凭证、题目或答案。',
    if (_entries.any((entry) => entry._diagnostic))
      '测试心跳仅表示记录时 Dart 正在执行；原生状态为当时快照，不能证明持续后台运行。日志仅保留最近 500 条，10 秒一次心跳与快照约覆盖 40 分钟。',
    '',
    for (final entry in _entries)
      '${entry.time.toLocal().toIso8601String()}  ${entry.message}',
  ].join('\n');

  Future<File> exportDocument({Directory? directory}) async {
    await initialize();
    final output = directory ?? await getTemporaryDirectory();
    await output.create(recursive: true);
    return File(
      '${output.path}/ykt-helper-logs-${DateTime.now().millisecondsSinceEpoch}.txt',
    ).writeAsString(document(), flush: true);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
