import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/ui/automation_page.dart';

class _MemoryStore implements KeyValueStore {
  final values = <String, String>{};
  final settingsWrites = <Json>[];

  AppSettings get persisted =>
      AppSettings.fromJson(object(jsonDecode(values['settings']!)));

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    if (key == 'settings') settingsWrites.add(object(jsonDecode(value)));
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Autostart extends AppAutostart {
  Completer<void>? nextConfiguration;
  final configurationStarted = Completer<void>();

  @override
  bool get supported => true;

  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {
    final pending = nextConfiguration;
    nextConfiguration = null;
    if (pending != null) {
      configurationStarted.complete();
      await pending.future;
    }
  }

  @override
  Future<void> setSuspended(bool suspended) async {}
}

class _Background extends BackgroundRuntime {
  bool active = false;

  @override
  bool get supported => true;

  @override
  bool get enabled => active;

  @override
  bool get busy => false;

  @override
  Future<bool> setEnabled(bool enabled) async {
    active = enabled;
    return true;
  }
}

class _Ai extends AiAnswerService {
  int modelRequests = 0;

  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) async {
    modelRequests++;
    return ['saved-model'];
  }
}

Future<void> _mount(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(
    MaterialApp(home: AutomationPage(controller: controller)),
  );
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Finder target) async {
  tester.testTextInput.hide();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final complete in [true, false]) {
    testWidgets('答题关闭且AI配置${complete ? '完整' : '不完整'}时签到和服务独立持久化', (
      tester,
    ) async {
      final store = _MemoryStore();
      final ai = _Ai();
      final initial = AppSettings(
        answerMode: AnswerMode.ai,
        baseUrl: 'https://offline.invalid/v1',
        apiKey: complete ? 'offline-only' : '',
        model: complete ? 'saved-model' : '',
      );
      store.values['settings'] = jsonEncode(initial.toJson());
      final controller =
          AppController(
              store: store,
              ai: ai,
              autostart: _Autostart(),
              background: _Background(),
              startTimers: false,
              connectSockets: false,
            )
            ..initialized = true
            ..settings = initial;
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      expect(ai.modelRequests, 0);

      await tester.tap(find.byKey(const ValueKey('auto-enter')));
      await tester.pumpAndSettle();
      expect(controller.settings.autoEnter, isTrue);
      expect(store.persisted.autoEnter, isTrue);
      expect(controller.settings.autoAnswer, isFalse);
      expect(store.persisted.autoAnswer, isFalse);
      expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
      expect(ai.modelRequests, 0);

      await tester.tap(find.byKey(const ValueKey('auto-start-service')));
      await tester.pumpAndSettle();
      expect(controller.settings.autoStartService, isTrue);
      expect(store.persisted.autoStartService, isTrue);
      expect(controller.settings.autoEnter, isTrue);
      expect(store.persisted.autoAnswer, isFalse);
      expect(store.settingsWrites, hasLength(2));
      expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
      expect(ai.modelRequests, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('重新开启不完整AI答题时仍不持久化开启状态', (tester) async {
    final store = _MemoryStore();
    final ai = _Ai();
    final initial = AppSettings(
      autoEnter: true,
      answerMode: AnswerMode.ai,
      baseUrl: 'https://offline.invalid/v1',
    );
    store.values['settings'] = jsonEncode(initial.toJson());
    final controller =
        AppController(
            store: store,
            ai: ai,
            autostart: _Autostart(),
            background: _Background(),
            startTimers: false,
            connectSockets: false,
          )
          ..initialized = true
          ..settings = initial;
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    await tester.tap(find.byKey(const ValueKey('auto-answer')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, isFalse);
    expect(store.persisted.autoAnswer, isFalse);
    expect(store.persisted.autoEnter, isTrue);
    expect(store.settingsWrites, isEmpty);
    expect(find.byKey(const ValueKey('automation-save-error')), findsOneWidget);
    expect(ai.modelRequests, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无效答案保持持久化配置，关闭自动提交即时保存且补全后不复活', (tester) async {
    final store = _MemoryStore();
    final initial = AppSettings(
      autoAnswer: true,
      autoSubmit: true,
      fixedSubjectiveAnswer: '旧内容',
    );
    store.values['settings'] = jsonEncode(initial.toJson());
    final controller =
        AppController(
            store: store,
            autostart: _Autostart(),
            background: _Background(),
            startTimers: false,
            connectSockets: false,
          )
          ..initialized = true
          ..settings = initial;
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    expect(store.settingsWrites, isEmpty);

    final subjectiveAnswer = find.byKey(
      const ValueKey('field-fixedSubjective'),
    );
    await _show(tester, subjectiveAnswer);
    await tester.enterText(subjectiveAnswer, '');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSubjectiveAnswer, '旧内容');
    expect(store.persisted.fixedSubjectiveAnswer, '旧内容');
    expect(store.settingsWrites, isEmpty);
    expect(
      tester.widget<TextField>(subjectiveAnswer).controller!.text,
      isEmpty,
    );

    final autoSubmit = find.byKey(const ValueKey('auto-submit'));
    await _show(tester, autoSubmit);
    await tester.tap(autoSubmit);
    await tester.pumpAndSettle();
    expect(controller.settings.autoSubmit, isFalse);
    expect(store.persisted.autoSubmit, isFalse);
    expect(store.persisted.fixedSubjectiveAnswer, '旧内容');
    expect(store.settingsWrites, hasLength(1));

    await _show(tester, subjectiveAnswer);
    await tester.enterText(subjectiveAnswer, 'C');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSubjectiveAnswer, 'C');
    expect(store.persisted.fixedSubjectiveAnswer, 'C');
    expect(store.persisted.fixedSingleAnswer, 'A');
    expect(store.persisted.fixedMultipleAnswer, 'AB');
    expect(controller.settings.autoSubmit, isFalse);
    expect(store.persisted.autoSubmit, isFalse);
    expect(store.settingsWrites, hasLength(2));
    expect(
      store.settingsWrites.every((value) => value['autoSubmit'] == false),
      isTrue,
    );
    expect(tester.widget<TextField>(subjectiveAnswer).controller!.text, 'C');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('原生保存挂起时继续编辑，最终持久化最新答案且通知不覆盖输入', (tester) async {
    final store = _MemoryStore();
    final initial = AppSettings(autoAnswer: true, fixedSubjectiveAnswer: '旧内容');
    store.values['settings'] = jsonEncode(initial.toJson());
    final releaseConfiguration = Completer<void>();
    final autostart = _Autostart()..nextConfiguration = releaseConfiguration;
    final controller =
        AppController(
            store: store,
            autostart: autostart,
            background: _Background(),
            startTimers: false,
            connectSockets: false,
          )
          ..initialized = true
          ..settings = initial;
    addTearDown(() {
      if (!releaseConfiguration.isCompleted) releaseConfiguration.complete();
      controller.dispose();
    });
    await _mount(tester, controller);
    final subjectiveAnswer = find.byKey(
      const ValueKey('field-fixedSubjective'),
    );
    await _show(tester, subjectiveAnswer);

    await tester.enterText(subjectiveAnswer, 'B');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(autostart.configurationStarted.isCompleted, isTrue);
    expect(controller.settings.fixedSubjectiveAnswer, '旧内容');
    expect(store.persisted.fixedSubjectiveAnswer, 'B');

    await tester.enterText(subjectiveAnswer, 'C');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final inputController = tester
        .widget<TextField>(subjectiveAnswer)
        .controller!;
    expect(inputController.text, 'C');
    expect(controller.settings.fixedSubjectiveAnswer, '旧内容');
    final notifications = <({String active, String input})>[];
    void recordNotification() {
      notifications.add((
        active: controller.settings.fixedSubjectiveAnswer,
        input: inputController.text,
      ));
    }

    controller.addListener(recordNotification);
    releaseConfiguration.complete();
    await tester.pumpAndSettle();
    controller.removeListener(recordNotification);

    expect(controller.settings.fixedSubjectiveAnswer, 'C');
    expect(store.persisted.fixedSubjectiveAnswer, 'C');
    expect(store.persisted.fixedSingleAnswer, 'A');
    expect(store.persisted.fixedMultipleAnswer, 'AB');
    expect(inputController.text, 'C');
    expect(
      store.settingsWrites.map((value) => value['fixedSubjectiveAnswer']),
      ['B', 'C'],
    );
    expect(notifications.any((value) => value.active == 'B'), isTrue);
    expect(notifications.every((value) => value.input == 'C'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
