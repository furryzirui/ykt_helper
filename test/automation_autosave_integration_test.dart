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

  Json get persistedJson => object(jsonDecode(values['settings']!));
  AppSettings get persisted => AppSettings.fromJson(persistedJson);

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
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {}

  @override
  Future<BackgroundRuntimeState?> status() async =>
      BackgroundRuntimeState(enabled: active);

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

class _PendingAi extends AiAnswerService {
  final requests = <Completer<List<String>>>[];

  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) {
    final request = Completer<List<String>>();
    requests.add(request);
    return request.future;
  }
}

AppController _controller(
  _MemoryStore store,
  AppSettings initial, {
  AiAnswerService? ai,
}) {
  store.values['settings'] = jsonEncode(initial.toJson());
  return AppController(
      store: store,
      ai: ai ?? _Ai(),
      autostart: _Autostart(),
      background: _Background(),
      startTimers: false,
      connectSockets: false,
    )
    ..initialized = true
    ..settings = initial;
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

Finder _field(String name) => find.byKey(ValueKey('field-$name'));

Future<void> _edit(WidgetTester tester, String name, String value) async {
  await _show(tester, _field(name));
  await tester.enterText(_field(name), value);
  await tester.pump(const Duration(milliseconds: 601));
  await tester.pumpAndSettle();
}

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('automation-status'))).data!;

Future<void> _navigationMount(
  WidgetTester tester,
  AppController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => AutomationPage(controller: controller),
              ),
            ),
            child: const Text('打开自动化'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开自动化'));
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
      await tester.tap(find.widgetWithText(FilledButton, '确认开启'));
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

  testWidgets('重新开启不完整AI答题时持久化开启状态并提示配置原因', (tester) async {
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
    expect(controller.settings.autoAnswer, isTrue);
    expect(store.persisted.autoAnswer, isTrue);
    expect(store.persisted.autoEnter, isTrue);
    expect(store.settingsWrites, hasLength(1));
    expect(find.byKey(const ValueKey('automation-save-error')), findsOneWidget);
    expect(_status(tester), isNot(contains('已自动保存')));
    expect(_status(tester), contains('api_key'));
    expect(ai.modelRequests, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('空答案原样持久化，关闭自动提交即时保存且补全后不复活', (tester) async {
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
    expect(controller.settings.fixedSubjectiveAnswer, isEmpty);
    expect(store.persisted.fixedSubjectiveAnswer, isEmpty);
    expect(store.persistedJson['fixedSubjectiveAnswer'], isEmpty);
    expect(store.settingsWrites, hasLength(1));
    expect(_status(tester), isNot(contains('已自动保存')));
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
    expect(store.persisted.fixedSubjectiveAnswer, isEmpty);
    expect(store.settingsWrites, hasLength(2));

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
    expect(store.settingsWrites, hasLength(3));
    expect(
      store.settingsWrites
          .skip(1)
          .every((value) => value['autoSubmit'] == false),
      isTrue,
    );
    expect(tester.widget<TextField>(subjectiveAnswer).controller!.text, 'C');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('启用AI后清空地址会落盘，返回重开与迟到模型结果不能恢复旧地址', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _MemoryStore();
    final ai = _PendingAi();
    final controller = _controller(
      store,
      AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://offline.invalid/v1',
        apiKey: 'offline-only',
        model: 'saved-model',
      ),
      ai: ai,
    );
    addTearDown(controller.dispose);
    await _navigationMount(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    expect(ai.requests, hasLength(1));

    await _show(tester, _field('baseUrl'));
    await tester.enterText(_field('baseUrl'), '');
    // Back must flush even before the text debounce fires.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AutomationPage), findsNothing);
    expect(controller.settings.baseUrl, isEmpty);
    expect(controller.settings.model, isEmpty);
    expect(store.persisted.baseUrl, isEmpty);
    expect(store.persisted.model, isEmpty);
    expect(store.persistedJson['baseUrl'], isEmpty);

    ai.requests.single.complete(['late-model']);
    await tester.pumpAndSettle();
    expect(controller.settings.baseUrl, isEmpty);
    expect(controller.settings.model, isEmpty);
    expect(store.persisted.baseUrl, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('打开自动化'));
    await tester.pumpAndSettle();
    await _show(tester, _field('baseUrl'));
    expect(
      tester.widget<TextField>(_field('baseUrl')).controller!.text,
      isEmpty,
    );
    expect(controller.settings.autoAnswer, isTrue);
    expect(_status(tester), startsWith('请填写有效的 AI base_url'));
    expect(_status(tester), contains('base_url'));
    expect(find.text('late-model'), findsNothing);
    expect(ai.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AI密钥模型提示词可清空并持久化，重新读取不会填回默认值', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _MemoryStore();
    final controller = _controller(
      store,
      AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://offline.invalid/v1',
        apiKey: 'offline-only',
        model: 'saved-model',
        customPrompt: '原提示词：{question}',
      ),
    );
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pumpAndSettle();
    await _edit(tester, 'apiKey', '');
    expect(controller.settings.apiKey, isEmpty);
    expect(controller.settings.model, isEmpty);
    expect(store.persisted.apiKey, isEmpty);
    expect(store.persisted.model, isEmpty);
    expect(store.persistedJson['apiKey'], isEmpty);
    expect(store.persistedJson['model'], isEmpty);

    await _edit(tester, 'prompt', '');
    expect(controller.settings.customPrompt, isEmpty);
    expect(store.persisted.customPrompt, isEmpty);
    expect(store.persistedJson['customPrompt'], isEmpty);
    expect(_status(tester), isNot(contains('已自动保存')));

    await tester.pumpWidget(const SizedBox());
    controller.settings = store.persisted;
    await _mount(tester, controller);
    await _show(tester, _field('apiKey'));
    expect(
      tester.widget<TextField>(_field('apiKey')).controller!.text,
      isEmpty,
    );
    await _show(tester, _field('prompt'));
    expect(
      tester.widget<TextField>(_field('prompt')).controller!.text,
      isEmpty,
    );
    expect(controller.settings.model, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('固定主观多选空值和非法延迟全部原样保存，修正提示不阻止落盘', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _MemoryStore();
    final controller = _controller(
      store,
      AppSettings(autoAnswer: true, autoSubmit: true),
    );
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    await _edit(tester, 'fixedSubjective', '');
    expect(controller.settings.fixedSubjectiveAnswer, isEmpty);
    expect(store.persisted.fixedSubjectiveAnswer, isEmpty);

    final multipleA = find.byKey(const ValueKey('fixedMultiple-A'));
    final multipleB = find.byKey(const ValueKey('fixedMultiple-B'));
    await _show(tester, multipleA);
    await tester.tap(multipleA);
    await tester.pumpAndSettle();
    await tester.tap(multipleB);
    await tester.pumpAndSettle();
    expect(controller.settings.fixedMultipleAnswer, isEmpty);
    expect(store.persisted.fixedMultipleAnswer, isEmpty);
    expect(store.persistedJson['fixedMultipleAnswer'], isEmpty);

    for (final invalid in ['0', '3601']) {
      await _edit(tester, 'submitDelay', invalid);
      expect(controller.settings.autoSubmitDelaySeconds, int.parse(invalid));
      expect(store.persisted.autoSubmitDelaySeconds, int.parse(invalid));
      expect(store.persistedJson['autoSubmitDelaySeconds'], int.parse(invalid));
      expect(controller.settings.autoSubmit, isTrue);
      expect(_status(tester), isNot(contains('已自动保存')));
      expect(_status(tester), contains('提交延迟'));
    }
    await tester.pumpWidget(const SizedBox());
    controller.settings = store.persisted;
    await _mount(tester, controller);
    await _show(tester, _field('submitDelay'));
    expect(
      tester.widget<TextField>(_field('submitDelay')).controller!.text,
      '3601',
    );
    await _show(tester, _field('fixedSubjective'));
    expect(
      tester.widget<TextField>(_field('fixedSubjective')).controller!.text,
      isEmpty,
    );
    expect(controller.settings.fixedMultipleAnswer, isEmpty);
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
    expect(controller.settings.fixedSubjectiveAnswer, 'B');
    expect(store.persisted.fixedSubjectiveAnswer, 'B');

    await tester.enterText(subjectiveAnswer, 'C');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final inputController = tester
        .widget<TextField>(subjectiveAnswer)
        .controller!;
    expect(inputController.text, 'C');
    expect(controller.settings.fixedSubjectiveAnswer, 'B');
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
