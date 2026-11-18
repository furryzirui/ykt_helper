import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
      for (var i = 0; i < 520; i++) {
        logs.add(AppLogEvent.attendance, success: i.isEven, count: i);
      }
      await logs.flush();
      expect(logs.entries.length, 500);
      logs.dispose();
      final restored = AppLogs(fileProvider: () async => file);
      await restored.initialize();
      expect(restored.entries.length, 500);
      expect(restored.entries.first.count, 519);
      expect(restored.entries.last.count, 20);
      final exported = await restored.exportDocument(directory: directory);
      expect(exported.path, endsWith('.txt'));
      expect(await exported.readAsString(), contains('读取签到状态 · 失败 · 数量 519'));
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
}
