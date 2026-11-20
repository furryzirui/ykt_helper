import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_logs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ykt-helper-logs-test-');
    file = File('${directory.path}/events.jsonl');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'release removes temporary test logs while restoring ordinary events',
    () async {
      final time = DateTime.now().toIso8601String();
      await file.writeAsString(
        [
          for (final event in [
            'backgroundHeartbeat',
            'backgroundSnapshot',
            'login',
          ])
            jsonEncode({'time': time, 'event': event, 'success': true}),
        ].join('\n'),
      );
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      await logs.flush();
      expect(logs.entries.single.event, AppLogEvent.login);
      expect(await file.readAsString(), isNot(contains('backgroundHeartbeat')));
      expect(await file.readAsString(), isNot(contains('backgroundSnapshot')));
      logs.dispose();
    },
  );

  test(
    'bounded event log persists across restart and exports readable text',
    () async {
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      for (var i = 0; i < AppLogs.maxEntries + 20; i++) {
        logs.add(AppLogEvent.attendance, success: i.isEven, count: i);
      }
      await logs.flush();
      expect(logs.entries.length, AppLogs.maxEntries);
      logs.dispose();
      final restored = AppLogs(fileProvider: () async => file);
      await restored.initialize();
      expect(restored.entries.length, AppLogs.maxEntries);
      expect(restored.entries.first.count, AppLogs.maxEntries + 19);
      expect(restored.entries.last.count, 20);
      final exported = await restored.exportDocument(directory: directory);
      expect(exported.path, endsWith('.txt'));
      expect(
        await exported.readAsString(),
        contains('读取签到状态 · 失败 · 数量 ${AppLogs.maxEntries + 19}'),
      );
      await restored.flush();
      restored.dispose();
    },
  );

  test(
    'restoring reconstructs allowlisted schema and drops private fields',
    () async {
      await file.writeAsString(
        [
          jsonEncode({
            'time': DateTime.now().toIso8601String(),
            'event': 'login',
            'success': false,
            'cookie': 'private-cookie',
            'api_key': 'private-key',
            'answer': 'private-answer',
            'url': 'https://private.invalid/token',
          }),
          'incomplete-json',
          jsonEncode({
            'time': DateTime.now().toIso8601String(),
            'event': 'private-question',
          }),
        ].join('\n'),
      );
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      await logs.flush();
      expect(logs.entries.length, 1);
      final content = await file.readAsString();
      expect(content, isNot(contains('private')));
      expect(logs.document(), isNot(contains('private')));
      logs.dispose();
    },
  );

  test('storage failure keeps current events available for export', () async {
    final logs = AppLogs(
      fileProvider: () async => throw const FileSystemException('unavailable'),
    );
    logs.add(AppLogEvent.background, success: false);
    await logs.initialize();
    expect(logs.storageUnavailable, isTrue);
    expect(logs.entries.single.event, AppLogEvent.background);
    final exported = await logs.exportDocument(directory: directory);
    expect(await exported.readAsString(), contains('后台服务检查 · 失败'));
    logs.dispose();
  });

  test(
    'export waits for stored history while initialization is pending',
    () async {
      await file.writeAsString(
        jsonEncode({
          'time': DateTime.now().toIso8601String(),
          'event': 'login',
          'success': true,
        }),
      );
      final provider = Completer<File>();
      final logs = AppLogs(fileProvider: () => provider.future);
      final initialization = logs.initialize();
      var completed = false;
      final export = logs.exportDocument(directory: directory).then((file) {
        completed = true;
        return file;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      provider.complete(file);
      await initialization;
      final exported = await export;
      expect(await exported.readAsString(), contains('登录 · 成功'));
      await logs.flush();
      logs.dispose();
    },
  );

  test(
    'detail view, restored entries and exported document retain the same useful diagnostics',
    () async {
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      logs.add(
        AppLogEvent.automatic,
        success: false,
        code: 429,
        detail: '模型请求已完成，未生成可用答案',
        error: const ApiFailure('模型服务返回 HTTP 429，请稍后重试'),
        context: {
          'phase': 'generate',
          'problemId': 'problem-3',
          'lessonId': 'lesson-1',
          'attempt': 2,
          'mode': 'ai',
          'requested': true,
        },
        elapsed: const Duration(milliseconds: 1234),
      );
      final detail = logs.entries.single.detailText;
      expect(detail, contains('耗时：1234 ms'));
      expect(detail, contains('phase：generate'));
      expect(detail, contains('problemId：problem-3'));
      expect(detail, contains('原因：模型服务返回 HTTP 429，请稍后重试'));
      expect(logs.document(), contains(detail));
      await logs.flush();
      logs.dispose();
      final restored = AppLogs(fileProvider: () async => file);
      await restored.initialize();
      expect(restored.entries.single.detailText, detail);
      final exported = await restored.exportDocument(directory: directory);
      expect(await exported.readAsString(), contains(detail));
      await restored.flush();
      restored.dispose();
    },
  );

  test(
    'sensitive lines, structured bodies and private context never reach memory, disk or export',
    () async {
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      logs.add(
        AppLogEvent.api,
        success: false,
        detail:
            '请求资格检查失败\nAuthorization: Bearer private-bearer\nCookie: sessionid=private-cookie\nanswer: private-answer\n正文检查未完成',
        error: const ApiFailure(
          '拒绝请求\napi_key: private-api-key\ncontent: private-slide-content\nbody: private-request-body',
        ),
        context: {
          'phase': 'eligibility',
          'route': '/api/v3/lesson/checkin?token=private-query',
          'api_key': 'private-context-key',
          'answer': 'private-context-answer',
          'payload': {'title': 'private-payload'},
          'headers': {'Cookie': 'private-header'},
        },
      );
      logs.add(
        AppLogEvent.automatic,
        detail: '响应内容 {"answer":"private-json-answer"}',
        error:
            'Bearer private-bare-bearer https://ai.example/chat?api_key=private-url-key',
      );
      final document = logs.document();
      expect(document, contains('请求资格检查失败'));
      expect(document, contains('正文检查未完成'));
      expect(document, contains('/api/v3/lesson/checkin'));
      expect(document, isNot(contains('private-')));
      await logs.flush();
      expect(await file.readAsString(), isNot(contains('private-')));
      final export = await logs.exportDocument(directory: directory);
      expect(await export.readAsString(), isNot(contains('private-')));
      logs.dispose();
    },
  );

  test(
    'Dio and generic errors expose failure class but never request data or exception bodies',
    () {
      final logs = AppLogs();
      final request = RequestOptions(
        path: 'https://private.example/token',
        headers: {'Authorization': 'Bearer private-key'},
        data: {'answer': 'private-answer'},
      );
      logs.add(
        AppLogEvent.api,
        error: DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: request,
            statusCode: 403,
            data: {'content': 'private-response'},
          ),
        ),
      );
      logs.add(AppLogEvent.failure, error: Exception('private-exception-body'));
      logs.add(
        AppLogEvent.failure,
        error: const FormatException('private-malformed', 'private-source'),
      );
      logs.add(
        AppLogEvent.failure,
        error: const FileSystemException('private-file-error', '/private/file'),
      );
      expect(logs.document(), contains('badResponse（HTTP 403）'));
      expect(logs.document(), contains('发生 _Exception'));
      expect(logs.document(), isNot(contains('private-')));
      logs.dispose();
    },
  );

  test(
    'imported detail and context are sanitized again and oversized explanations are bounded',
    () async {
      await file.writeAsString(
        jsonEncode({
          'time': DateTime.now().toIso8601String(),
          'event': 'automatic',
          'detail': 'Authorization: Bearer private-import-key',
          'error': 'result: private-import-answer',
          'context': {
            'phase': 'failed',
            'body': 'private-import-body',
            'route': '/endpoint?api_key=private-import-query',
          },
          'elapsedMs': 12,
        }),
      );
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      await logs.flush();
      expect(logs.document(), isNot(contains('private-')));
      expect(await file.readAsString(), isNot(contains('private-')));
      logs.add(
        AppLogEvent.failure,
        detail: List.filled(2000, '错').join(),
        error: PlatformException(
          code: 'denied',
          message: 'Permission is denied',
          details: {'token': 'private-native-detail'},
        ),
      );
      expect(logs.entries.first.detail!.length, lessThanOrEqualTo(1201));
      expect(logs.entries.first.error, 'denied：Permission is denied');
      expect(logs.entries.first.context, isEmpty);
      await logs.flush();
      logs.dispose();
    },
  );
  test(
    'registered credentials redact unlabeled server echoes and earlier history without persisting the registry',
    () async {
      await file.writeAsString(
        jsonEncode({
          'time': DateTime.now().toIso8601String(),
          'event': 'api',
          'error': '服务器拒绝 tiny-custom-key',
        }),
      );
      final logs = AppLogs(fileProvider: () async => file);
      await logs.initialize();
      logs.protectSecrets([
        'tiny-custom-key',
        'old-classroom-bearer',
        'A',
        'key',
      ]);
      logs.add(
        AppLogEvent.failure,
        detail: 'tiny-custom-key 调用未完成',
        error: const ApiFailure('old-classroom-bearer 已过期'),
        context: {'phase': 'check', 'reason': 'tiny-custom-key'},
      );
      final content = logs.document();
      expect(content, isNot(contains('tiny-custom-key')));
      expect(content, isNot(contains('old-classroom-bearer')));
      expect(content, contains('凭证已隐藏'));
      logs.add(AppLogEvent.failure, detail: 'A key setting was checked');
      expect(logs.entries.first.detail, 'A key setting was checked');
      await logs.flush();
      expect(await file.readAsString(), isNot(contains('tiny-custom-key')));
      expect(
        await file.readAsString(),
        isNot(contains('old-classroom-bearer')),
      );
      final exported = await logs.exportDocument(directory: directory);
      expect(await exported.readAsString(), isNot(contains('tiny-custom-key')));
      logs.dispose();
    },
  );
}
