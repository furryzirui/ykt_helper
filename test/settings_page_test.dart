import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/app_autostart.dart';
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
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {}
  @override
  Future<BackgroundRuntimeState?> status() async => null;

  @override
  bool get enabled => true;
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _Autostart extends AppAutostart {
  String permission = 'granted';
  Object? error;
  Completer<String>? pending;
  Object? prepareError;
  int checks = 0, preparations = 0, configurations = 0;

  @override
  Future<String> permissionStatus() async {
    checks++;
    if (pending != null) return pending!.future;
    if (error != null) throw error!;
    return permission;
  }

  @override
  Future<void> prepare() async {
    preparations++;
    if (prepareError != null) throw prepareError!;
  }

  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {
    configurations++;
  }
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
  Object? saveError;
  bool normalizeAutostart = false;
  final snapshots = <AppSettings>[];
  _Controller(_Ai ai, {AppAutostart? autostart})
    : super(
        ai: ai,
        store: _Store(),
        background: _Background(),
        autostart: autostart ?? _Autostart(),
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
  }
  @override
  Future<void> saveSettings([AppSettings? next]) async {
    saves++;
    final candidate = AppSettings.fromJson((next ?? settings).toJson());
    candidate.customPrompt = (next ?? settings).customPrompt;
    candidate.autoSubmitDelaySeconds =
        (next ?? settings).autoSubmitDelaySeconds;
    snapshots.add(candidate);
    await pendingSave?.future;
    if (saveError != null) throw saveError!;
    if (normalizeAutostart) candidate.appAutoStart = false;
    settings = candidate;
    saved = candidate;
    notifyListeners();
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

Future<void> _reveal(
  WidgetTester tester,
  Finder target, {
  double delta = 240,
}) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find.byType(Scrollable).first,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pump();
  expect(target.hitTestable(), findsOneWidget);
}

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

Finder _setting(String key) => find.byKey(ValueKey(key));

Finder _switch(String key) =>
    find.descendant(of: _setting(key), matching: find.byType(Switch));

State _switchState(WidgetTester tester, String key) => tester.state(
  find
      .descendant(
        of: _switch(key),
        matching: find.byWidgetPredicate((widget) => widget is StatefulWidget),
      )
      .first,
);

Future<void> _settleSave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 601));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final field = _setting('field-$key');
  await _reveal(tester, field);
  await tester.enterText(field, text);
}

void main() {
  testWidgets('右上角只显示保存结果，连续保存期间无加载图标或结果闪空', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true);
    await _show(tester, controller);
    expect(tester.widget<Text>(_setting('automation-status')).data, isEmpty);
    await _reveal(tester, _setting('fixedSingle-B'));
    await tester.tap(_setting('fixedSingle-B'));
    await tester.pumpAndSettle();
    expect(find.text('已自动保存'), findsOneWidget);
    final gate = Completer<void>();
    controller.pendingSave = gate;
    await tester.tap(_setting('fixedSingle-C'));
    await tester.pump();
    expect(controller.settings.fixedSingleAnswer, 'B');
    expect(find.text('已自动保存'), findsOneWidget);
    expect(find.byIcon(Icons.sync_rounded), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<AppBar>(find.byType(AppBar)).bottom, isNull);
    gate.complete();
    controller.pendingSave = null;
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSingleAnswer, 'C');
    expect(find.text('已自动保存'), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('慢速模型发现不闪临时错误，选择模型只更新右上角保存结果', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'key',
      );
    await _show(tester, controller);
    await _reveal(tester, find.text('自定义 AI'));
    await tester.tap(find.text('自定义 AI'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    expect(controller.settings.answerMode, AnswerMode.ai);
    await tester.pump(const Duration(milliseconds: 600));
    expect(ai.requests, hasLength(1));
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('正在获取模型…'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    expect(controller.settings.answerMode, AnswerMode.ai);
    ai.requests.single.response.complete(['model-a', 'model-b']);
    await tester.pumpAndSettle();
    expect(controller.settings.model, 'model-a');
    expect(find.text('已自动保存'), findsOneWidget);
    expect(find.text('已选择首个模型，可切换'), findsNothing);
    final gate = Completer<void>();
    controller.pendingSave = gate;
    final selector = find.byWidgetPredicate(
      (widget) => widget is DropdownButtonFormField<String>,
    );
    tester.widget<DropdownButtonFormField<String>>(selector).onChanged!(
      'model-b',
    );
    await tester.pump();
    expect(find.text('已自动保存'), findsOneWidget);
    expect(find.byIcon(Icons.sync_rounded), findsNothing);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    gate.complete();
    controller.pendingSave = null;
    await tester.pumpAndSettle();
    expect(controller.settings.model, 'model-b');
    expect(find.text('已自动保存'), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('模型失败仅显示右上角原因，点击状态可重试且不重复页内提示', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'key',
        model: 'known',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.single.response.completeError(
      const ApiFailure('模型服务返回 HTTP 404'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('模型服务返回 HTTP 404'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: _setting('automation-status'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<AppBar>(find.byType(AppBar)).bottom, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(_setting('automation-status'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(ai.requests, hasLength(2));
    expect(find.textContaining('模型服务返回 HTTP 404'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    ai.requests.last.response.complete(['known']);
    await tester.pumpAndSettle();
    expect(controller.saves, 0);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('刷新模型列表会清除旧失败原因并等待新请求结果', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'key',
        model: 'known',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.single.response.completeError(
      const ApiFailure('模型服务返回 HTTP 404'),
    );
    await tester.pumpAndSettle();
    await tester.tap(_setting('auto-enter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('模型服务返回 HTTP 404'), findsOneWidget);
    await _reveal(tester, find.byTooltip('刷新模型列表'));
    await tester.tap(find.byTooltip('刷新模型列表'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(ai.requests, hasLength(2));
    expect(find.textContaining('模型服务返回 HTTP 404'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    ai.requests.last.response.complete(['known']);
    await tester.pumpAndSettle();
    expect(controller.settings.autoEnter, isTrue);
    expect(find.text('已自动保存'), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('Windows关闭AI答题时签到和自启无需获取模型即可自动保存', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'key',
        model: 'known',
      );
    await _show(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(_setting('auto-enter'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoEnter, isTrue);
    expect(controller.settings.autoAnswer, isFalse);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(controller.settings.appAutoStart, isTrue);
    expect(controller.settings.model, 'known');
    expect(controller.settings.apiKey, 'key');
    expect(ai.requests, isEmpty);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('获取模型期间关闭自动答题会清除保存错误且忽略迟到模型结果', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoEnter: true,
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'key',
        model: 'known',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    expect(ai.requests, hasLength(1));
    await tester.tap(_setting('auto-answer'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, isFalse);
    expect(controller.settings.autoEnter, isTrue);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    ai.requests.single.response.complete(['different-model']);
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, isFalse);
    expect(controller.settings.model, 'known');
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('首次加载和无变化模型刷新不保存，也不显示保存按钮', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'key',
        model: 'known',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.single.response.complete(['known', 'other']);
    await tester.pumpAndSettle();
    expect(controller.saves, 0);
    expect(find.text('保存设置'), findsNothing);
    expect(find.text('保存中…'), findsNothing);
    await _reveal(tester, find.byTooltip('刷新模型列表'));
    await tester.tap(find.byTooltip('刷新模型列表'));
    await tester.pump(const Duration(milliseconds: 1));
    ai.requests.last.response.complete(['known', 'other']);
    await tester.pumpAndSettle();
    expect(controller.saves, 0);
    await _close(tester, controller);
  });

  testWidgets('服务和自动化开关立即保存，自启动常驻并说明前置条件', (tester) async {
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    final appStart = _setting('app-auto-start');
    expect(tester.widget<SwitchListTile>(appStart).onChanged, isNull);
    expect(find.text('请在启用自动启动服务后开启'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(_setting('auto-start-service')).onChanged,
      isNull,
    );
    await tester.tap(_setting('auto-enter'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoEnter, isTrue);
    await tester.tap(_setting('auto-start-service'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoStartService, isTrue);
    expect(find.text('请在启用自动启动服务后开启'), findsNothing);
    await tester.tap(appStart);
    await tester.pumpAndSettle();
    expect(find.textContaining('确认后自动保存'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.settings.appAutoStart, isFalse);
    await tester.tap(appStart);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(controller.settings.appAutoStart, isTrue);
    await tester.tap(_setting('auto-start-service'));
    await tester.pumpAndSettle();
    expect(controller.settings.appAutoStart, isFalse);
    expect(tester.widget<SwitchListTile>(appStart).onChanged, isNull);
    expect(find.text('请在启用自动启动服务后开启'), findsOneWidget);
    await _close(tester, controller);
  });

  for (final permission in ['needsConfirmation', 'error']) {
    testWidgets('Windows未知权限$permission允许用途确认与自动保存', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final autostart = _Autostart()..permission = permission;
      if (permission == 'error') autostart.error = StateError('unavailable');
      final controller = _Controller(_Ai(), autostart: autostart)
        ..settings = AppSettings(autoEnter: true);
      await _show(tester, controller);
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
        isNotNull,
      );
      expect(find.text('应用权限'), findsNothing);
      expect(find.text('清除自启动设置'), findsNothing);
      await tester.tap(_setting('app-auto-start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启'));
      await tester.pumpAndSettle();
      expect(autostart.preparations, 1);
      expect(controller.settings.appAutoStart, isTrue);
      await _close(tester, controller);
    });
  }

  testWidgets('Windows读取期间禁止新开启，明确禁用时可关闭已有偏好', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final pending = Completer<String>();
    final autostart = _Autostart()..pending = pending;
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    pending.complete('denied');
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    controller.settings = AppSettings(autoEnter: true, appAutoStart: true);
    controller.showBackgroundWarning(null);
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isTrue,
    );
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNotNull,
    );
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    expect(controller.settings.appAutoStart, isFalse);
    expect(autostart.preparations, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows开启前复查，确认后注册失败不会生效', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart();
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    await tester.pump();
    autostart.permission = 'denied';
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    autostart.permission = 'granted';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    autostart.prepareError = const ApiFailure('failed');
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法添加自启动项，请重试'), findsOneWidget);
    expect(controller.settings.appAutoStart, isFalse);
    expect(controller.saves, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows系统禁用已有自启时仍可立即关闭自动答题', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart()..permission = 'denied';
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(
        autoEnter: true,
        autoAnswer: true,
        appAutoStart: true,
      );
    await _show(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(_setting('auto-answer'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, false);
    expect(controller.settings.autoEnter, true);
    expect(controller.settings.appAutoStart, true);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('Windows过期权限查询等待最新结果，不把陈旧请求当成禁用', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart();
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    await tester.pump();
    final first = Completer<String>(), second = Completer<String>();
    autostart.pending = first;
    await tester.tap(_setting('app-auto-start'));
    autostart.pending = second;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    first.complete('granted');
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    second.complete('needsConfirmation');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('系统已禁用自启动'), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('iOS自启动常驻禁用且可选后台方案，Windows无需服务显示完成图标', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    expect(_setting('app-auto-start'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    expect(find.text('iOS 不支持应用自启动'), findsOneWidget);
    expect(find.text('静音音频保活'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _show(tester, controller);
    await tester.pump();
    expect(find.widgetWithText(SwitchListTile, '自动启动服务'), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('固定单选多选用A–D控件并立即保存，主观文本600ms保存', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true);
    await _show(tester, controller);
    expect(
      tester.widget<ChoiceChip>(_setting('fixedSingle-A')).selected,
      isTrue,
    );
    expect(
      tester.widget<FilterChip>(_setting('fixedMultiple-A')).selected,
      isTrue,
    );
    expect(
      tester.widget<FilterChip>(_setting('fixedMultiple-B')).selected,
      isTrue,
    );
    await _reveal(tester, _setting('fixedSingle-C'));
    await tester.tap(_setting('fixedSingle-C'));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSingleAnswer, 'C');
    await tester.tap(_setting('fixedMultiple-D'));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedMultipleAnswer, 'ABD');
    expect(
      tester.widget<ChoiceChip>(_setting('fixedJudgment-A')).selected,
      isTrue,
    );
    await _reveal(tester, _setting('fixedJudgment-B'));
    await tester.tap(_setting('fixedJudgment-B'));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedJudgmentAnswer, 'B');
    expect(controller.settings.fixedSingleAnswer, 'C');
    expect(
      tester.getTopLeft(_setting('input-fixedMultiple')).dy,
      lessThan(tester.getTopLeft(_setting('input-fixedJudgment')).dy),
    );
    await _type(tester, 'fixedSubjective', '同一个答案');
    await tester.pump(const Duration(milliseconds: 599));
    expect(
      controller.settings.fixedSubjectiveAnswer,
      defaultFixedSubjectiveAnswer,
    );
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSubjectiveAnswer, '同一个答案');
    expect(find.text('每个空使用相同内容'), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('无效旧选项不默认选中，清空多选仍自动保存并提示原因', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(
        autoAnswer: true,
        fixedSingleAnswer: 'AB',
        fixedMultipleAnswer: 'AE',
      );
    await _show(tester, controller);
    for (final option in ['A', 'B', 'C', 'D']) {
      expect(
        tester.widget<ChoiceChip>(_setting('fixedSingle-$option')).selected,
        isFalse,
      );
      expect(
        tester.widget<FilterChip>(_setting('fixedMultiple-$option')).selected,
        isFalse,
      );
    }
    await _reveal(tester, _setting('fixedSingle-B'));
    await tester.tap(_setting('fixedSingle-B'));
    await tester.pump();
    expect(controller.saves, 1);
    await tester.tap(_setting('fixedMultiple-C'));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSingleAnswer, 'B');
    expect(controller.settings.fixedMultipleAnswer, 'C');
    await tester.tap(_setting('fixedMultiple-C'));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedMultipleAnswer, isEmpty);
    expect(
      tester.widget<FilterChip>(_setting('fixedMultiple-C')).selected,
      isFalse,
    );
    expect(find.textContaining('请选择 A–D 范围内的单选和多选答案'), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('无效输入也自动保存，关闭自动提交和答题仍立即生效', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true, autoSubmit: true);
    await _show(tester, controller);
    await _type(tester, 'fixedSubjective', '');
    await _settleSave(tester);
    expect(controller.saves, 1);
    expect(controller.settings.fixedSubjectiveAnswer, isEmpty);
    expect(find.textContaining('请填写全部固定答案'), findsOneWidget);
    await _reveal(tester, _setting('auto-submit'));
    await tester.tap(_setting('auto-submit'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoSubmit, isFalse);
    expect(controller.settings.autoAnswer, isTrue);
    await tester.tap(_setting('auto-answer'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, isFalse);
    await tester.tap(_setting('auto-answer'));
    await tester.pumpAndSettle();
    await _reveal(tester, _setting('field-fixedSubjective'));
    expect(
      tester
          .widget<TextField>(_setting('field-fixedSubjective'))
          .controller!
          .text,
      '',
    );
    await _close(tester, controller);
  });

  testWidgets('延迟非法仍保存并提示原因，修正后清除提示', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true, autoSubmit: true);
    await _show(tester, controller);
    await _type(tester, 'submitDelay', '0');
    await _settleSave(tester);
    expect(controller.saves, 1);
    expect(controller.settings.autoSubmitDelaySeconds, 0);
    expect(find.textContaining('提交延迟请输入'), findsOneWidget);
    await _type(tester, 'submitDelay', '45');
    await _settleSave(tester);
    expect(controller.settings.autoSubmitDelaySeconds, 45);
    expect(find.byKey(const ValueKey('automation-save-error')), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('保存期间继续输入和开关，controller通知不会覆盖最新编辑', (tester) async {
    final gate = Completer<void>();
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true)
      ..pendingSave = gate;
    await _show(tester, controller);
    await _type(tester, 'fixedSubjective', 'B');
    await tester.pump(const Duration(milliseconds: 601));
    expect(controller.saves, 1);
    expect(
      tester.widget<TextField>(_setting('field-fixedSubjective')).enabled,
      isTrue,
    );
    await _type(tester, 'fixedSubjective', 'C');
    await tester.pump(const Duration(milliseconds: 601));
    await _reveal(tester, _setting('auto-submit'));
    await tester.tap(_setting('auto-submit'));
    controller.showBackgroundWarning(null);
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('auto-submit')).value,
      isTrue,
    );
    gate.complete();
    controller.pendingSave = null;
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSubjectiveAnswer, 'C');
    expect(controller.settings.autoSubmit, isTrue);
    expect(controller.snapshots.first.fixedSubjectiveAnswer, 'B');
    expect(controller.snapshots.last.fixedSubjectiveAnswer, 'C');
    await _close(tester, controller);
  });

  testWidgets('失败保留编辑值并可重试，成功后不显示保存按钮', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true)
      ..saveError = const ApiFailure('保存失败');
    await _show(tester, controller);
    await _type(tester, 'fixedSubjective', 'C');
    await _settleSave(tester);
    expect(
      controller.settings.fixedSubjectiveAnswer,
      defaultFixedSubjectiveAnswer,
    );
    expect(
      tester
          .widget<TextField>(_setting('field-fixedSubjective'))
          .controller!
          .text,
      'C',
    );
    expect(find.textContaining('保存失败'), findsOneWidget);
    controller.saveError = null;
    await tester.tap(_setting('automation-status'));
    await tester.pumpAndSettle();
    expect(controller.settings.fixedSubjectiveAnswer, 'C');
    expect(find.text('保存设置'), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('controller规范化的开关状态会同步回界面', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoEnter: true, autoStartService: true)
      ..normalizeAutostart = true;
    await _show(tester, controller);
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(controller.settings.appAutoStart, isFalse);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isFalse,
    );
    expect(find.textContaining('未保存'), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('AI未配齐也保存，模型自动选择和空提示词均持久化', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(autoAnswer: true);
    await _show(tester, controller);
    await _reveal(tester, find.text('自定义 AI'));
    await tester.tap(find.text('自定义 AI'));
    await tester.pump();
    expect(controller.settings.answerMode, AnswerMode.ai);
    expect(find.textContaining('请填写有效的 AI base_url'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: _setting('automation-status'),
      ),
      findsOneWidget,
    );
    await _type(tester, 'baseUrl', 'https://ai.example.com/v1');
    await _type(tester, 'apiKey', 'key');
    await tester.pump(const Duration(milliseconds: 501));
    expect(ai.requests, hasLength(1));
    ai.requests.single.response.complete(['vision-a', 'vision-b']);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(controller.settings.answerMode, AnswerMode.ai);
    expect(controller.settings.model, 'vision-a');
    await _type(tester, 'prompt', '');
    await _settleSave(tester);
    expect(controller.settings.customPrompt, isEmpty);
    expect(find.textContaining('请填写 AI 提示词'), findsOneWidget);
    await _type(tester, 'prompt', '只输出：{question}');
    await _settleSave(tester);
    expect(controller.settings.customPrompt, '只输出：{question}');
    await _reveal(tester, _setting('slide-scope'));
    tester
        .widget<DropdownButtonFormField<SlideScope>>(_setting('slide-scope'))
        .onChanged!(SlideScope.currentAndNext);
    await tester.pumpAndSettle();
    await _type(tester, 'slidePrompt', '请参考定义');
    await _settleSave(tester);
    expect(controller.settings.slidePrompt, '请参考定义');
    expect(controller.settings.slideScope, SlideScope.currentAndNext);
    await _close(tester, controller);
  });

  testWidgets('旧模型返回不能覆盖新地址，发现错误不回显密钥', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://old.example.com/v1',
        apiKey: 'private-key',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    await _type(tester, 'baseUrl', 'https://new.example.com/v1');
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.first.response.complete(['old-model']);
    await tester.pump();
    expect(find.text('old-model'), findsNothing);
    ai.requests.last.response.completeError(StateError('private-key'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.textContaining('模型列表获取失败，请检查地址和密钥后重试'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: _setting('automation-status'),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains('private-key') ?? false),
      ),
      findsNothing,
    );
    expect(controller.saves, greaterThan(0));
    expect(controller.settings.baseUrl, 'https://new.example.com/v1');
    expect(controller.settings.model, isEmpty);
    await _close(tester, controller);
  });

  testWidgets('返回页面立即flush尚未debounce的输入，无额外确认', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true);
    await tester.binding.setSurfaceSize(const Size(800, 1500));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AutomationPage(controller: controller),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _type(tester, 'fixedSubjective', '返回前的内容');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AutomationPage), findsNothing);
    expect(controller.settings.fixedSubjectiveAnswer, '返回前的内容');
    expect(find.byType(AlertDialog), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('dispose会flush有效输入且迟到保存不调用setState', (tester) async {
    final gate = Completer<void>();
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true)
      ..pendingSave = gate;
    await _show(tester, controller);
    await _type(tester, 'fixedSubjective', '离开后保存');
    await tester.pumpWidget(const SizedBox());
    expect(controller.saves, 1);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(controller.settings.fixedSubjectiveAnswer, '离开后保存');
    expect(tester.takeException(), isNull);
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('AI未完成草稿返回后保留，重新进入发现模型后继续保存', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(autoAnswer: true);
    final draft = AutomationDraft();
    await tester.binding.setSurfaceSize(const Size(800, 1500));
    await tester.pumpWidget(
      MaterialApp(
        home: AutomationPage(controller: controller, draft: draft),
      ),
    );
    await _reveal(tester, find.text('自定义 AI'));
    await tester.tap(find.text('自定义 AI'));
    await tester.pump();
    await _type(tester, 'baseUrl', 'https://ai.example.com/v1');
    await _type(tester, 'apiKey', 'key');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(controller.settings.answerMode, AnswerMode.ai);
    expect(draft.settings!.baseUrl, 'https://ai.example.com/v1');
    await tester.pumpWidget(
      MaterialApp(
        home: AutomationPage(controller: controller, draft: draft),
      ),
    );
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.last.response.complete(['vision']);
    await tester.pumpAndSettle();
    expect(controller.settings.answerMode, AnswerMode.ai);
    expect(controller.settings.model, 'vision');
    await _close(tester, controller);
  });

  testWidgets('开关动画保留各自状态和固定行位置', (tester) async {
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    const keys = [
      'auto-start-service',
      'app-auto-start',
      'auto-enter',
      'auto-answer',
    ];
    final states = {for (final key in keys) key: _switchState(tester, key)};
    final rects = {for (final key in keys) key: tester.getRect(_setting(key))};
    for (final key in [
      'auto-enter',
      'auto-start-service',
      'auto-answer',
      'auto-submit',
    ]) {
      await tester.tap(_setting(key));
      await tester.pump(const Duration(milliseconds: 20));
      for (final fixed in keys) {
        expect(_switchState(tester, fixed), same(states[fixed]));
        expect(tester.getRect(_setting(fixed)), rects[fixed]);
      }
    }
    expect(tester.widget<Switch>(_switch('auto-submit')).value, isTrue);
    await _close(tester, controller);
  });

  testWidgets('设置导航保留应用权限日志关于入口，成功后台提示静默', (tester) async {
    const channel = MethodChannel('ykt_helper/app_permissions');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'camera': 'denied',
        'notifications': 'granted',
        'photos': 'notRequired',
        'battery': 'granted',
        'autostart': 'needsConfirmation',
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
    for (final title in ['应用权限', '自动化', '应用日志', '关于']) {
      expect(find.text(title), findsOneWidget);
    }
    await tester.tap(find.text('自动化'));
    await tester.pumpAndSettle();
    await tester.tap(_setting('auto-enter'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoEnter, isTrue);
    expect(find.text('后台课堂服务已开启'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用权限'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(controller.backgroundRetries, 1);
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    await _close(tester, controller);
  });
}
