import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/services/app_logs.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/background_diagnostics.dart';

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
    'background test observations persist whitelisted snapshots without claiming keepalive success',
    () async {
      final snapshot = IosBackgroundSnapshot.parse({
        'enabled': true,
        'mode': 'pictureInPicture',
        'appState': 'background',
        'audioPlaying': false,
        'audioTimeMs': 125,
        'pipActive': true,
        'pipFrameCount': 100,
        'cookie': 'secret-cookie',
        'location': 'private-coordinate',
        'message': 'private-error-text',
      });
      final logs = AppLogs(
        fileProvider: () async => file,
        iosBackgroundDiagnostics: true,
      );
      await logs.initialize();
      logs.addBackgroundHeartbeat(
        mode: BackgroundServiceMode.pictureInPicture,
        foreground: false,
      );
      logs.addBackgroundSnapshot(
        mode: BackgroundServiceMode.pictureInPicture,
        snapshot: snapshot,
      );
      await logs.flush();
      expect(logs.entries.first.message, contains('画中画累计送帧 100'));
      expect(logs.entries.first.message, contains('音频位置 125 ms'));
      expect(logs.entries.first.message, isNot(contains('成功')));
      expect(logs.entries.last.message, contains('Dart 后台执行'));
      final content = await file.readAsString();
      expect(content, isNot(contains('secret')));
      expect(content, isNot(contains('private')));
      expect(logs.document(), contains('不能证明持续后台运行'));
      logs.dispose();
      final restored = AppLogs(
        fileProvider: () async => file,
        iosBackgroundDiagnostics: true,
      );
      await restored.initialize();
      expect(restored.entries.length, 2);
      expect(restored.entries.first.backgroundSnapshot!.pipFrameCount, 100);
      await restored.flush();
      restored.dispose();
    },
  );

  test(
    'default builds neither add nor restore background test observations',
    () async {
      expect(iosBackgroundDiagnosticsEnabled, false);
      final logs = AppLogs(fileProvider: () async => file);
      logs.addBackgroundHeartbeat(
        mode: BackgroundServiceMode.silentAudio,
        foreground: false,
      );
      logs.addBackgroundSnapshot(
        mode: BackgroundServiceMode.silentAudio,
        snapshot: null,
      );
      logs.add(AppLogEvent.backgroundHeartbeat);
      expect(logs.entries, isEmpty);
      await file.writeAsString(
        jsonEncode({
          'time': DateTime.now().toIso8601String(),
          'event': 'backgroundHeartbeat',
          'backgroundMode': 'silentAudio',
          'foreground': false,
        }),
      );
      await logs.initialize();
      await logs.flush();
      expect(logs.entries, isEmpty);
      expect(await file.readAsString(), isEmpty);
      logs.dispose();
    },
  );

  test(
    'a mismatched native snapshot labels the observed mode separately from configuration',
    () {
      final logs = AppLogs(iosBackgroundDiagnostics: true);
      logs.addBackgroundSnapshot(
        mode: BackgroundServiceMode.silentAudio,
        snapshot: IosBackgroundSnapshot.parse({
          'enabled': true,
          'mode': 'pictureInPicture',
          'appState': 'background',
          'pipActive': true,
          'pipFrameCount': 20,
        }),
      );
      final entry = logs.entries.single;
      expect(entry.message, contains('原生方案 画中画'));
      expect(entry.message, contains('配置方案 静音音频'));
      expect(
        entry.backgroundSnapshot!.mode,
        BackgroundServiceMode.pictureInPicture,
      );
      logs.dispose();
    },
  );

  test(
    'diagnostic numeric fields reject invalid values and free text during log import',
    () {
      final snapshot = IosBackgroundSnapshot.parse({
        'enabled': true,
        'mode': 'silentAudio',
        'appState': 'background',
        'audioPlaying': 'private',
        'audioTimeMs': -10,
        'pipActive': 'private',
        'pipFrameCount': 9007199254740992,
      });
      expect(snapshot!.toJson(), {
        'enabled': true,
        'mode': 'silentAudio',
        'appState': 'background',
      });
      final entry = AppLogEntry.parse({
        'time': DateTime.now().toIso8601String(),
        'event': 'backgroundSnapshot',
        'backgroundMode': 'private-mode',
        'foreground': 'private',
        'backgroundSnapshot': {
          ...snapshot.toJson(),
          'cookie': 'private-cookie',
        },
      });
      expect(jsonEncode(entry!.toJson()), isNot(contains('private')));
    },
  );

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
