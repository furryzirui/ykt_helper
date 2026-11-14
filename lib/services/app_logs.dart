import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum AppLogEvent {
  startup('启动'),
  login('登录'),
  logout('退出登录'),
  refresh('刷新课程与动态'),
  settings('保存自动化设置'),
  background('后台服务检查'),
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
  const AppLogEntry({
    required this.time,
    required this.event,
    this.success,
    this.code,
    this.count,
  });

  String get message => [
    event.label,
    if (success != null) success! ? '成功' : '失败',
    if (code != null) '状态码 $code',
    if (count != null) '数量 $count',
  ].join(' · ');

  Map<String, Object?> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'event': event.name,
    if (success != null) 'success': success,
    if (code != null) 'code': code,
    if (count != null) 'count': count,
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
    );
  }
}

/// A bounded local event log. Only enum labels and numeric results are accepted:
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
  AppLogs({this.fileProvider});

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
              if (entry != null) saved.add(entry);
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
    if (_disposed) return;
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
