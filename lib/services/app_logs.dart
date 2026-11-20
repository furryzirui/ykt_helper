import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

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
  final String? detail, error;
  final Map<String, Object?> context;
  final int? elapsedMs;
  const AppLogEntry({
    required this.time,
    required this.event,
    this.success,
    this.code,
    this.count,
    this.detail,
    this.error,
    this.context = const {},
    this.elapsedMs,
  });

  String get message => [
    event.label,
    if (success != null) success! ? '成功' : '失败',
    if (code != null) '状态码 $code',
    if (count != null) '数量 $count',
  ].join(' · ');

  String get detailText => [
    '${time.toLocal().toIso8601String()}  $message',
    if (elapsedMs != null) '耗时：$elapsedMs ms',
    for (final entry in _LogPrivacy.context(context).entries)
      '${entry.key}：${entry.value}',
    if (_LogPrivacy.text(detail) case final String value) '详情：$value',
    if (_LogPrivacy.text(error) case final String value) '原因：$value',
  ].join('\n');

  Map<String, Object?> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'event': event.name,
    if (success != null) 'success': success,
    if (code != null) 'code': code,
    if (count != null) 'count': count,
    if (_LogPrivacy.text(detail) case final String value) 'detail': value,
    if (_LogPrivacy.text(error) case final String value) 'error': value,
    if (context.isNotEmpty) 'context': _LogPrivacy.context(context),
    if (elapsedMs != null) 'elapsedMs': elapsedMs,
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
      detail: _LogPrivacy.text(raw['detail']),
      error: _LogPrivacy.text(raw['error']),
      context: _LogPrivacy.context(raw['context']),
      elapsedMs: raw['elapsedMs'] is int && raw['elapsedMs'] >= 0
          ? raw['elapsedMs']
          : null,
    );
  }
}

class _LogPrivacy {
  static const _contextKeys = {
    'phase',
    'method',
    'route',
    'lessonId',
    'problemId',
    'presentationId',
    'questionType',
    'attempt',
    'generation',
    'delaySeconds',
    'reason',
    'source',
    'enabled',
    'requested',
    'mode',
    'presentationCount',
    'questionCount',
    'answerCount',
    'slideCount',
    'pendingCount',
    'retry',
    'platform',
  };
  static final _sensitiveAssignment = RegExp(
    r'''(?:authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|secret|sessionid|csrftoken|answer|answers|result|prompt|content|body|payload|response|request|messages?|题目|答案|课件正文|请求体)["'\s]*[:=：]''',
    caseSensitive: false,
  );

  /// Only short caller-authored explanations are supported. Structured server
  /// bodies and credential-bearing lines are discarded, never pretty-printed.
  static String? text(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    var value = raw.trim();
    value = value
        .split(RegExp(r'[\r\n]+'))
        .map((line) {
          if (_sensitiveAssignment.hasMatch(line)) return '[已隐藏敏感数据]';
          final objectStart = line.indexOf(
            RegExp(r'\{|\[(?!已隐藏|地址已隐藏|密钥已隐藏|令牌已隐藏|标识已隐藏|邮箱已隐藏|手机号已隐藏|凭证已隐藏)'),
          );
          if (objectStart >= 0) {
            return '${line.substring(0, objectStart)}[已隐藏结构化数据]';
          }
          return line;
        })
        .join('\n');
    value = value
        .replaceAll(
          RegExp(r'https?://[^\s<>"\x27]+', caseSensitive: false),
          '[地址已隐藏]',
        )
        .replaceAll(
          RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
          'Bearer [已隐藏]',
        )
        .replaceAll(
          RegExp(r'(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+'),
          '[密钥已隐藏]',
        )
        .replaceAll(
          RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
          '[令牌已隐藏]',
        )
        .replaceAll(RegExp(r'[A-Za-z0-9+/=_-]{48,}'), '[标识已隐藏]')
        .replaceAll(
          RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
          '[邮箱已隐藏]',
        )
        .replaceAll(RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)'), '[手机号已隐藏]')
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
    return value.length > 1200 ? '${value.substring(0, 1200)}…' : value;
  }

  static Map<String, Object?> context(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, Object?>{};
    var textBudget = 1600;
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String || !_contextKeys.contains(key)) continue;
      final value = entry.value;
      if (value is bool || value is int || value is double && value.isFinite) {
        result[key] = value;
      } else if (value is String) {
        var safe = text(value);
        if (key == 'route') {
          final path = value.split(RegExp(r'[?#]')).first;
          safe = RegExp(r'^/[A-Za-z0-9/_-]{1,180}$').hasMatch(path)
              ? path
              : '[地址已隐藏]';
        }
        if (safe != null && textBudget > 0) {
          final length = safe.length.clamp(0, textBudget.clamp(0, 180));
          result[key] = safe.length > length
              ? '${safe.substring(0, length)}…'
              : safe;
          textBudget -= length;
        }
      }
    }
    return Map.unmodifiable(result);
  }

  static String? failure(Object? failure) {
    if (failure == null) return null;
    if (failure is DioException) {
      final status = failure.response?.statusCode;
      return '网络请求失败：${failure.type.name}${status == null ? '' : '（HTTP $status）'}';
    }
    if (failure is ApiFailure) return text(failure.message);
    if (failure is PlatformException) {
      return text(
        '${failure.code}${failure.message == null ? '' : '：${failure.message}'}',
      );
    }
    if (failure is TimeoutException) return '操作超时';
    if (failure is SocketException) {
      return '网络连接失败${failure.osError?.errorCode == null ? '' : '（错误码 ${failure.osError!.errorCode}）'}';
    }
    if (failure is FileSystemException) {
      return '文件系统操作失败${failure.osError?.errorCode == null ? '' : '（错误码 ${failure.osError!.errorCode}）'}';
    }
    if (failure is FormatException) return '数据格式无效';
    if (failure is String) return text(failure);
    // Generic exception strings may contain full responses, prompts or files.
    return '发生 ${failure.runtimeType}';
  }
}

/// Bounded diagnostics. Callers provide static explanations and allowlisted
/// identifiers only, never question text, personal answers or raw request data.
/// Imported records pass through the same privacy filter before persistence.
class AppLogs extends ChangeNotifier {
  static const maxEntries = 1000;
  final Future<File> Function()? fileProvider;
  final List<AppLogEntry> _entries = [];
  final Set<String> _protectedSecrets = {};
  File? _file;
  Future<void> _writes = Future.value();
  Future<void>? _initializing;
  bool _disposed = false;
  bool storageUnavailable = false;
  AppLogs({this.fileProvider});

  List<AppLogEntry> get entries => List.unmodifiable(_entries.reversed);

  /// Registers credentials in memory for exact redaction, including short
  /// custom keys that have no recognizable prefix. Values are never persisted.
  /// Keep earlier credentials until disposal to cover late asynchronous errors.
  void protectSecrets(Iterable<String> values) {
    if (_disposed) return;
    final before = _protectedSecrets.length;
    _protectedSecrets.addAll(values.where((value) => value.trim().length >= 4));
    if (before == _protectedSecrets.length) return;
    for (var index = 0; index < _entries.length; index++) {
      _entries[index] = _protectEntry(_entries[index]);
    }
    _persist();
    notifyListeners();
  }

  String? _privateText(String? value) {
    if (value == null) return null;
    var safe = value;
    final secrets = _protectedSecrets.toList()
      ..sort((first, second) => second.length.compareTo(first.length));
    for (final secret in secrets) {
      safe = safe.replaceAll(secret, '[凭证已隐藏]');
    }
    return _LogPrivacy.text(safe);
  }

  AppLogEntry _protectEntry(AppLogEntry entry) => AppLogEntry(
    time: entry.time,
    event: entry.event,
    success: entry.success,
    code: entry.code,
    count: entry.count,
    detail: _privateText(entry.detail),
    error: _privateText(entry.error),
    context: _LogPrivacy.context({
      for (final item in entry.context.entries)
        item.key: item.value is String
            ? _privateText(item.value as String)
            : item.value,
    }),
    elapsedMs: entry.elapsedMs,
  );

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      final file = await (fileProvider?.call() ?? _defaultFile());
      final saved = <AppLogEntry>[];
      if (await file.exists()) {
        // Avoid reading an accidentally oversized or replaced file into memory.
        if (await file.length() <= 16 * 1024 * 1024) {
          for (final line in await file.readAsLines()) {
            try {
              final entry = AppLogEntry.parse(jsonDecode(line));
              if (entry != null) saved.add(_protectEntry(entry));
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

  void add(
    AppLogEvent event, {
    bool? success,
    int? code,
    int? count,
    String? detail,
    Object? error,
    Map<String, Object?> context = const {},
    Duration? elapsed,
  }) {
    if (_disposed) return;
    _entries.add(
      _protectEntry(
        AppLogEntry(
          time: DateTime.now(),
          event: event,
          success: success,
          code: code,
          count: count,
          detail: _LogPrivacy.text(detail),
          error: _LogPrivacy.failure(error),
          context: _LogPrivacy.context(context),
          elapsedMs: elapsed?.inMilliseconds,
        ),
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
    '记录操作阶段、耗时、错误原因和课堂/题目标识；不记录账号、凭证、题目正文、个人答案或请求体。分享前请确认其中标识信息。',
    '',
    for (final entry in _entries) '${entry.detailText}\n',
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
