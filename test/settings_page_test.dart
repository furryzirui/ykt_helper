import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/ui/permissions_page.dart';
import 'package:ykt_helper/ui/settings_page.dart';
import 'package:ykt_helper/ui/automation_page.dart';
import 'package:ykt_helper/ui/about_page.dart';

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Background extends BackgroundRuntime {
  @override
  bool get enabled => true;
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _ModelRequest {
  final String baseUrl, apiKey;
  final response = Completer<List<String>>();
  _ModelRequest(this.baseUrl, this.apiKey);
}

class _Ai extends AiAnswerService {
  final requests = <_ModelRequest>[];
  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) {
    final request = _ModelRequest(baseUrl, apiKey);
    requests.add(request);
    return request.response.future;
  }
}

class _Controller extends AppController {
  int saves = 0;
  int backgroundRetries = 0;
  AppSettings? saved;
  Completer<void>? pendingSave;
  _Controller(_Ai ai)
    : super(
        ai: ai,
        store: _Store(),
        background: _Background(),
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
  }
  @override
  Future<void> saveSettings([AppSettings? next]) async {
    saves++;
    final candidate = AppSettings.fromJson((next ?? settings).toJson());
    await pendingSave?.future;
    settings = candidate;
    saved = candidate;
  }

  void showBackgroundWarning(String? warning) {
    backgroundWarning = warning;
    notifyListeners();
  }

  @override
  Future<void> retryBackground() async {
    backgroundRetries++;
  }
}

Finder _input(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _show(WidgetTester tester, _Controller controller) async {
  await tester.binding.setSurfaceSize(const Size(800, 1500));
  await tester.pumpWidget(
    MaterialApp(home: AutomationPage(controller: controller)),
  );
}

Future<void> _close(WidgetTester tester, _Controller controller) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
  await tester.binding.setSurfaceSize(null);
}

void main() {
  testWidgets(
    'pending and failed saves keep the effective settings unchanged',
    (tester) async {
      final gate = Completer<void>();
      final controller = _Controller(_Ai())..pendingSave = gate;
      await _show(tester, controller);
      await tester.tap(find.text('自动答题'));
      await tester.pump();
      await tester.enterText(_input('固定答案'), 'A');
      await tester.ensureVisible(find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(find.text('保存中…'), findsOneWidget);
      expect(controller.settings.autoAnswer, isFalse);
      expect(controller.settings.fixedAnswer, isEmpty);
      gate.completeError(const ApiFailure('保存失败'));
      await tester.pump();
      await tester.pump();
      expect(controller.settings.autoAnswer, isFalse);
      expect(find.text('保存失败'), findsOneWidget);
      controller.pendingSave = null;
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      await tester.pump();
      expect(controller.settings.autoAnswer, isTrue);
      expect(controller.settings.fixedAnswer, 'A');
      await _close(tester, controller);
    },
  );

  testWidgets(
    'settings remove UA and diagnostics; automatic submit stays a draft',
    (tester) async {
      final controller = _Controller(_Ai());
      await _show(tester, controller);
      expect(find.text('User-Agent'), findsNothing);
      expect(find.text('导出诊断信息'), findsNothing);
      expect(find.text('自动进入课堂'), findsNothing);
      expect(find.text('自动签到'), findsOneWidget);
      await tester.tap(find.text('自动签到'));
      await tester.tap(find.text('自动答题'));
      await tester.pump();
      final submit = find.widgetWithText(SwitchListTile, '自动提交');
      expect(tester.widget<SwitchListTile>(submit).value, isFalse);
      await tester.tap(find.text('自动提交'));
      await tester.enterText(_input('固定答案'), 'A');
      expect(controller.settings.autoAnswer, isFalse);
      expect(controller.settings.autoSubmit, isFalse);
      expect(controller.settings.autoEnter, isFalse);
      await tester.ensureVisible(find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(controller.saved!.autoAnswer, isTrue);
      expect(controller.saved!.autoSubmit, isTrue);
      expect(controller.saved!.autoEnter, isTrue);
      expect(controller.saved!.fixedAnswer, 'A');
      await _close(tester, controller);
    },
  );

  testWidgets(
    'background success stays silent while actual failure is visible',
    (tester) async {
      final controller = _Controller(_Ai())
        ..settings = AppSettings(autoEnter: true);
      await _show(tester, controller);
      expect(find.text('后台课堂服务已开启'), findsNothing);
      expect(find.text('后台课堂服务未开启'), findsNothing);
      controller.showBackgroundWarning('后台运行未开启，请允许通知和后台运行');
      await tester.pump();
      expect(find.text('后台运行未开启，请允许通知和后台运行'), findsOneWidget);
      controller.showBackgroundWarning(null);
      await tester.pump();
      expect(find.text('后台运行未开启，请允许通知和后台运行'), findsNothing);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'settings contain navigation and keep an unsaved automation draft',
    (tester) async {
      const channel = MethodChannel('ykt_helper/app_permissions');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'camera': 'denied',
          'notifications': 'granted',
          'photos': 'notRequired',
          'battery': 'granted',
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final controller = _Controller(_Ai());
      await tester.binding.setSurfaceSize(const Size(800, 1500));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(controller: controller)),
        ),
      );
      expect(find.text('自动签到'), findsNothing);
      expect(find.text('自动答题'), findsNothing);
      for (final title in ['应用权限', '自动化', '应用日志', '关于']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(
        tester.getTopLeft(find.text('应用日志')).dy,
        greaterThan(tester.getTopLeft(find.text('自动化')).dy),
      );
      expect(
        tester.getTopLeft(find.text('关于')).dy,
        greaterThan(tester.getTopLeft(find.text('应用日志')).dy),
      );
      await tester.tap(find.text('自动化'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动签到'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(controller.settings.autoEnter, isFalse);
      await tester.tap(find.text('应用权限'));
      await tester.pumpAndSettle();
      expect(find.byType(PermissionsPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(controller.backgroundRetries, 1);
      await tester.tap(find.text('自动化'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '自动签到'))
            .value,
        isTrue,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('紫锐飞跃'), findsOneWidget);
      expect(
        find.text('https://github.com/furryzirui/ykt_helper'),
        findsOneWidget,
      );
      await _close(tester, controller);
    },
  );

  testWidgets(
    'credentials debounce discovery; model and prompt apply only on save',
    (tester) async {
      final ai = _Ai();
      final controller = _Controller(ai)
        ..settings = AppSettings(autoAnswer: true, answerMode: AnswerMode.ai);
      await _show(tester, controller);
      await tester.enterText(_input('base_url'), 'https://old.example.com/v1');
      await tester.enterText(_input('base_url'), 'https://ai.example.com/v1');
      await tester.enterText(_input('api_key'), 'test-key');
      await tester.pump(const Duration(milliseconds: 499));
      expect(ai.requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 2));
      expect(ai.requests, hasLength(1));
      expect(ai.requests.single.baseUrl, 'https://ai.example.com/v1');
      expect(ai.requests.single.apiKey, 'test-key');
      expect(tester.widget<TextField>(_input('api_key')).obscureText, isTrue);
      expect(_input('模型'), findsNothing);
      ai.requests.single.response.complete(['vision-a', 'vision-b']);
      await tester.pump();
      await tester.pump();
      expect(find.text('已选择首个模型，可切换'), findsOneWidget);
      expect(controller.settings.model, isEmpty);
      await tester.tap(find.text('vision-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('vision-b').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_input('提示词'));
      await tester.enterText(_input('提示词'), '只输出结果：{question}');
      expect(controller.settings.customPrompt, defaultAiPrompt);
      await tester.ensureVisible(find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(controller.saved!.model, 'vision-b');
      expect(controller.saved!.customPrompt, '只输出结果：{question}');
      expect(controller.saved!.baseUrl, 'https://ai.example.com/v1');
      expect(ai.requests, hasLength(1));
      await _close(tester, controller);
    },
  );

  testWidgets(
    'late model results cannot replace models for changed credentials',
    (tester) async {
      final ai = _Ai();
      final controller = _Controller(ai)
        ..settings = AppSettings(
          autoAnswer: true,
          answerMode: AnswerMode.ai,
          baseUrl: 'https://old.example.com/v1',
          apiKey: 'old-key',
        );
      await _show(tester, controller);
      await tester.pump(const Duration(milliseconds: 501));
      expect(ai.requests, hasLength(1));
      await tester.enterText(_input('base_url'), 'https://new.example.com/v1');
      await tester.enterText(_input('api_key'), 'new-key');
      await tester.pump(const Duration(milliseconds: 501));
      expect(ai.requests, hasLength(2));
      ai.requests[0].response.complete(['old-model']);
      await tester.pump();
      expect(find.text('old-model'), findsNothing);
      ai.requests[1].response.complete(['new-model']);
      await tester.pump();
      await tester.pump();
      expect(find.text('new-model'), findsOneWidget);
      await tester.enterText(_input('api_key'), 'replacement-key');
      await tester.ensureVisible(find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(controller.saves, 0);
      expect(find.text('请先获取并选择当前 AI 服务的模型'), findsOneWidget);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'unknown discovery failures are shown without exception credentials',
    (tester) async {
      final ai = _Ai();
      final controller = _Controller(ai)
        ..settings = AppSettings(
          autoAnswer: true,
          answerMode: AnswerMode.ai,
          baseUrl: 'https://ai.example.com/v1',
          apiKey: 'private-key-value',
        );
      await _show(tester, controller);
      await tester.pump(const Duration(milliseconds: 501));
      ai.requests.single.response.completeError(
        StateError('echo private-key-value'),
      );
      await tester.pump();
      expect(find.text('模型列表获取失败，请检查地址和密钥后重试'), findsOneWidget);
      expect(find.textContaining('echo private-key-value'), findsNothing);
      await _close(tester, controller);
    },
  );

  testWidgets('a saved model remains selected when discovery lists it later', (
    tester,
  ) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'test-key',
        model: 'chosen-model',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.single.response.complete(['first-model', 'chosen-model']);
    await tester.pump();
    await tester.pump();
    expect(find.text('chosen-model'), findsOneWidget);
    expect(find.text('已选择首个模型，可切换'), findsNothing);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pump();
    expect(controller.saved!.model, 'chosen-model');
    await _close(tester, controller);
  });

  testWidgets(
    'changing mode invalidates discovery; a failed refresh blocks save',
    (tester) async {
      final ai = _Ai();
      final controller = _Controller(ai)
        ..settings = AppSettings(
          autoAnswer: true,
          answerMode: AnswerMode.ai,
          baseUrl: 'https://ai.example.com/v1',
          apiKey: 'test-key',
        );
      await _show(tester, controller);
      await tester.pump(const Duration(milliseconds: 501));
      await tester.tap(find.text('固定内容'));
      await tester.pump();
      ai.requests.single.response.complete(['stale-model']);
      await tester.pump();
      expect(find.text('stale-model'), findsNothing);
      expect(_input('固定答案'), findsOneWidget);
      await tester.tap(find.text('自定义 AI'));
      await tester.pump(const Duration(milliseconds: 501));
      ai.requests[1].response.complete(['current-model']);
      await tester.pump();
      await tester.pump();
      expect(find.text('current-model'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('刷新模型列表'));
      await tester.tap(find.byTooltip('刷新模型列表'));
      await tester.pump(const Duration(milliseconds: 1));
      expect(ai.requests, hasLength(3));
      ai.requests[2].response.completeError(const ApiFailure('模型列表获取失败'));
      await tester.pump();
      await tester.ensureVisible(find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(controller.saves, 0);
      expect(find.text('请先获取并选择当前 AI 服务的模型'), findsOneWidget);
      await _close(tester, controller);
    },
  );
}
