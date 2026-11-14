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
  bool get enabled => true;
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _Autostart extends AppAutostart {
  String permission = 'granted';
  Object? error;
  Completer<String>? pending;
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

void main() {
  testWidgets('应用自启动跟随服务开关，确认后仅保存草稿', (tester) async {
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    final appStart = find.widgetWithText(SwitchListTile, '应用自启动');
    final autoStart = find.widgetWithText(SwitchListTile, '自动启动服务');
    final autoEnter = find.widgetWithText(SwitchListTile, '自动签到');
    expect(appStart, findsOneWidget);
    expect(tester.widget<SwitchListTile>(appStart).onChanged, isNull);
    await tester.tap(autoEnter);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(appStart).onChanged, isNull);
    await tester.tap(autoStart);
    await tester.pump();
    expect(appStart, findsOneWidget);
    expect(
      tester.getTopLeft(appStart).dy,
      lessThan(tester.getTopLeft(autoEnter).dy),
    );
    await tester.tap(appStart);
    await tester.pumpAndSettle();
    expect(find.textContaining('保存设置后'), findsOneWidget);
    expect(controller.settings.appAutoStart, isFalse);
    expect(controller.saves, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(appStart).value, isFalse);
    await tester.tap(appStart);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(appStart).value, isTrue);
    expect(controller.settings.appAutoStart, isFalse);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.saved!.appAutoStart, isTrue);
    await tester.tap(autoStart);
    await tester.pump();
    expect(appStart, findsOneWidget);
    expect(tester.widget<SwitchListTile>(appStart).value, isFalse);
    expect(tester.widget<SwitchListTile>(appStart).onChanged, isNull);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.saved!.appAutoStart, isFalse);
    await _close(tester, controller);
  });

  testWidgets('Windows服务以完成状态显示，应用自启动保持可见', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    expect(find.widgetWithText(SwitchListTile, '自动启动服务'), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.text('自动化随应用运行，无需单独启动服务'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '应用自启动'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    await tester.tap(find.text('自动签到'));
    await tester.pump();
    expect(find.widgetWithText(SwitchListTile, '应用自启动'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    await _close(tester, controller);
  });

  for (final permission in [
    'pending',
    'denied',
    'needsConfirmation',
    'error',
  ]) {
    testWidgets('Windows自启动权限$permission时禁止开启并提供权限入口', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final autostart = _Autostart()..permission = permission;
      if (permission == 'pending') autostart.pending = Completer<String>();
      if (permission == 'error') autostart.error = StateError('unavailable');
      final controller = _Controller(_Ai(), autostart: autostart)
        ..settings = AppSettings(autoEnter: true);
      await _show(tester, controller);
      await tester.pump();
      final tile = tester.widget<SwitchListTile>(_setting('app-auto-start'));
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
      expect(_setting('app-auto-start-permissions'), findsOneWidget);
      if (permission == 'pending') {
        expect(find.text('正在检查自启动权限'), findsOneWidget);
      } else if (permission == 'error') {
        expect(find.text('无法读取权限，请在应用权限中重试'), findsOneWidget);
      } else {
        expect(find.text('请先在应用权限中允许自启动'), findsOneWidget);
      }
      await tester.tap(_setting('app-auto-start'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(autostart.preparations, 0);
      expect(autostart.configurations, 0);
      expect(controller.settings.appAutoStart, isFalse);
      await _close(tester, controller);
      autostart.pending?.complete('granted');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows开启前重新读取权限，不沿用进入页面时的授权结果', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart();
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNotNull,
    );
    expect(autostart.checks, 1);
    autostart.permission = 'denied';
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    expect(autostart.checks, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isFalse,
    );
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    expect(autostart.preparations, 0);
    expect(autostart.configurations, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows确认开启时再次检查权限，已撤销时不保存开启草稿', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart();
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    await tester.pump();
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(autostart.checks, 2);
    autostart.permission = 'denied';
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(autostart.checks, 3);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isFalse,
    );
    expect(_setting('app-auto-start-clear'), findsNothing);
    expect(autostart.preparations, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows已授权才可开启草稿，保存前撤销权限仍会阻止生效', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart();
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    await tester.pump();
    await tester.tap(_setting('app-auto-start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(autostart.checks, 3);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isTrue,
    );
    expect(controller.settings.appAutoStart, isFalse);
    expect(controller.saves, 0);
    autostart.permission = 'denied';
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(autostart.checks, 4);
    expect(controller.saves, 0);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isFalse,
    );
    expect(_setting('app-auto-start-clear'), findsOneWidget);
    expect(autostart.preparations, 0);
    expect(autostart.configurations, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows恢复前台刷新权限，撤销后显示关闭并允许清除旧偏好', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final autostart = _Autostart();
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true, appAutoStart: true);
    await _show(tester, controller);
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isTrue,
    );
    final gate = Completer<String>();
    autostart.pending = gate;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isFalse,
    );
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    gate.complete('denied');
    await tester.pumpAndSettle();
    expect(autostart.checks, 2);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).value,
      isFalse,
    );
    expect(controller.settings.appAutoStart, isTrue);
    await tester.tap(_setting('app-auto-start-clear'));
    await tester.pump();
    expect(_setting('app-auto-start-clear'), findsNothing);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.saved!.appAutoStart, isFalse);
    expect(autostart.preparations, 0);
    expect(autostart.configurations, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows权限页入口只导航，返回后重新检查授权状态', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final nativeCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      AppAutostart.channel,
      (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'status') {
          return {'enabled': false, 'permission': 'denied'};
        }
        throw PlatformException(code: 'unexpected_call');
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppAutostart.channel,
        null,
      ),
    );
    final autostart = _Autostart()..permission = 'denied';
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    await tester.pump();
    await tester.tap(_setting('app-auto-start-permissions'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsPage), findsOneWidget);
    expect(nativeCalls, ['status']);
    expect(autostart.preparations, 0);
    autostart.permission = 'granted';
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(autostart.checks, 2);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNotNull,
    );
    expect(nativeCalls, ['status']);
    expect(autostart.preparations, 0);
    await _close(tester, controller);
  });

  testWidgets('Windows迟到的权限结果不会覆盖恢复前台后的检查结果', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final first = Completer<String>(), second = Completer<String>();
    final autostart = _Autostart()..pending = first;
    final controller = _Controller(_Ai(), autostart: autostart)
      ..settings = AppSettings(autoEnter: true);
    await _show(tester, controller);
    autostart.pending = second;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    second.complete('denied');
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    first.complete('granted');
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    expect(find.text('请先在应用权限中允许自启动'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('iOS显示前台运行提示且不提供应用自启动', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoEnter: true, autoStartService: true);
    await _show(tester, controller);
    expect(find.text('当前平台需保持应用前台运行'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '自动启动服务'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, '应用自启动'), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('三类固定答案独立编辑，保存前不影响生效值', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true);
    await _show(tester, controller);
    const labels = ['单选 / 判断答案', '多选 / 投票答案', '主观 / 填空答案'];
    const defaults = [
      defaultFixedSingleAnswer,
      defaultFixedMultipleAnswer,
      defaultFixedSubjectiveAnswer,
    ];
    const values = ['C', 'ACD', '第一空\n第二空'];
    for (var i = 0; i < labels.length; i++) {
      await _reveal(tester, _input(labels[i]));
      expect(
        tester.widget<TextField>(_input(labels[i])).controller!.text,
        defaults[i],
      );
      await tester.enterText(_input(labels[i]), values[i]);
    }
    expect(controller.settings.fixedSingleAnswer, defaultFixedSingleAnswer);
    expect(controller.settings.fixedMultipleAnswer, defaultFixedMultipleAnswer);
    expect(
      controller.settings.fixedSubjectiveAnswer,
      defaultFixedSubjectiveAnswer,
    );
    await _reveal(tester, find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.saved!.fixedSingleAnswer, 'C');
    expect(controller.saved!.fixedMultipleAnswer, 'ACD');
    expect(controller.saved!.fixedSubjectiveAnswer, '第一空\n第二空');
    await _close(tester, controller);
  });

  testWidgets('课件额外提示词仅在发送课件时可编辑且保留草稿', (tester) async {
    final ai = _Ai();
    final controller = _Controller(ai)
      ..settings = AppSettings(
        autoAnswer: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'test-key',
        model: 'model',
      );
    await _show(tester, controller);
    await tester.pump(const Duration(milliseconds: 501));
    ai.requests.single.response.complete(['model']);
    await tester.pumpAndSettle();
    expect(_input('课件额外提示词'), findsNothing);
    final scope = find.byType(DropdownButtonFormField<SlideScope>);
    for (final value in [
      SlideScope.current,
      SlideScope.currentAndNext,
      SlideScope.all,
    ]) {
      tester.widget<DropdownButtonFormField<SlideScope>>(scope).onChanged!(
        value,
      );
      await tester.pump();
      await _reveal(tester, _input('课件额外提示词'));
      expect(
        tester.widget<TextField>(_input('课件额外提示词')).controller!.text,
        defaultSlidePrompt,
      );
    }
    await tester.enterText(_input('课件额外提示词'), '请优先参考课件中的定义');
    tester.widget<DropdownButtonFormField<SlideScope>>(scope).onChanged!(
      SlideScope.none,
    );
    await tester.pump();
    expect(_input('课件额外提示词'), findsNothing);
    tester.widget<DropdownButtonFormField<SlideScope>>(scope).onChanged!(
      SlideScope.current,
    );
    await tester.pump();
    await _reveal(tester, _input('课件额外提示词'));
    expect(
      tester.widget<TextField>(_input('课件额外提示词')).controller!.text,
      '请优先参考课件中的定义',
    );
    expect(controller.settings.slidePrompt, defaultSlidePrompt);
    await _reveal(tester, find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.saved!.slidePrompt, '请优先参考课件中的定义');
    expect(controller.saved!.slideScope, SlideScope.current);
    await _close(tester, controller);
  });

  testWidgets('自动启动服务位于顶部，仅在存在自动化项目时可开启', (tester) async {
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    final autoStart = find.widgetWithText(SwitchListTile, '自动启动服务');
    final autoEnter = find.widgetWithText(SwitchListTile, '自动签到');
    final autoAnswer = find.widgetWithText(SwitchListTile, '自动答题');
    expect(
      tester.getTopLeft(autoStart).dy,
      lessThan(tester.getTopLeft(autoEnter).dy),
    );
    expect(tester.widget<SwitchListTile>(autoStart).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(autoStart).value, isFalse);
    await tester.tap(autoEnter);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(autoStart).onChanged, isNotNull);
    await tester.tap(autoStart);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(autoStart).value, isTrue);
    expect(controller.settings.autoStartService, isFalse);
    await tester.tap(autoEnter);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(autoStart).value, isFalse);
    expect(tester.widget<SwitchListTile>(autoStart).onChanged, isNull);
    await tester.tap(autoAnswer);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(autoStart).onChanged, isNotNull);
    await _close(tester, controller);
  });

  testWidgets('切换动画期间固定开关行保留各自状态和位置', (tester) async {
    final controller = _Controller(_Ai());
    await _show(tester, controller);
    const keys = [
      'auto-start-service',
      'app-auto-start',
      'auto-enter',
      'auto-answer',
    ];
    final states = {for (final key in keys) key: _switchState(tester, key)};
    final rectangles = {
      for (final key in keys) key: tester.getRect(_setting(key)),
    };

    void checkFixedRows() {
      for (final key in keys) {
        expect(_switchState(tester, key), same(states[key]), reason: key);
        expect(tester.getRect(_setting(key)), rectangles[key], reason: key);
      }
      for (var i = 0; i < keys.length - 1; i++) {
        expect(
          tester.getBottomLeft(_setting(keys[i])).dy,
          lessThanOrEqualTo(tester.getTopLeft(_setting(keys[i + 1])).dy),
        );
      }
    }

    await tester.tap(_setting('auto-enter'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(tester.widget<Switch>(_switch('auto-enter')).value, isTrue);
    expect(tester.widget<Switch>(_switch('app-auto-start')).value, isFalse);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    await tester.tap(_setting('auto-start-service'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(tester.widget<Switch>(_switch('auto-start-service')).value, isTrue);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNotNull,
    );
    await tester.tap(_setting('auto-answer'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(tester.widget<Switch>(_switch('auto-answer')).value, isTrue);
    expect(tester.widget<Switch>(_switch('auto-submit')).value, isFalse);
    final submitState = _switchState(tester, 'auto-submit');
    await tester.tap(_setting('auto-submit'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(_switchState(tester, 'auto-submit'), same(submitState));
    expect(tester.widget<Switch>(_switch('auto-submit')).value, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('field-submitDelay')))
          .controller!
          .text,
      '30',
    );
    await tester.tap(_setting('auto-answer'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(_setting('auto-submit'), findsNothing);
    await tester.tap(_setting('auto-answer'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(tester.widget<Switch>(_switch('auto-submit')).value, isTrue);
    await tester.tap(_setting('auto-start-service'));
    await tester.pump(const Duration(milliseconds: 20));
    checkFixedRows();
    expect(tester.widget<Switch>(_switch('app-auto-start')).value, isFalse);
    expect(
      tester.widget<SwitchListTile>(_setting('app-auto-start')).onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('切换答题方式时输入状态不会被另一类字段复用', (tester) async {
    final controller = _Controller(_Ai())
      ..settings = AppSettings(autoAnswer: true);
    await _show(tester, controller);
    final fixedInput = find.byKey(const ValueKey('field-fixedSingle'));
    await _reveal(tester, fixedInput);
    await tester.enterText(fixedInput, 'C');
    final fixedState = tester.state(fixedInput);
    final fixedController = tester.widget<TextField>(fixedInput).controller;
    await _reveal(tester, find.text('自定义 AI'));
    await tester.tap(find.text('自定义 AI'));
    await tester.pump(const Duration(milliseconds: 20));
    final baseInput = find.byKey(const ValueKey('field-baseUrl'));
    final keyInput = find.byKey(const ValueKey('field-apiKey'));
    expect(fixedInput, findsNothing);
    expect(tester.state(baseInput), isNot(same(fixedState)));
    expect(
      tester.widget<TextField>(baseInput).controller,
      isNot(same(fixedController)),
    );
    expect(tester.widget<TextField>(baseInput).controller!.text, isEmpty);
    expect(tester.widget<TextField>(baseInput).obscureText, isFalse);
    expect(tester.widget<TextField>(keyInput).obscureText, isTrue);
    final baseState = tester.state(baseInput);
    await tester.enterText(baseInput, 'https://ai.example.com/v1');
    await tester.tap(find.text('固定内容'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(baseInput, findsNothing);
    expect(tester.state(fixedInput), isNot(same(baseState)));
    expect(
      tester.widget<TextField>(fixedInput).controller,
      same(fixedController),
    );
    expect(tester.widget<TextField>(fixedInput).controller!.text, 'C');
    expect(tester.widget<TextField>(fixedInput).obscureText, isFalse);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets(
    'submission delay appears only when enabled and validates before saving',
    (tester) async {
      final controller = _Controller(_Ai());
      await _show(tester, controller);
      expect(_input('提交延迟'), findsNothing);
      await tester.tap(find.text('自动答题'));
      await tester.pump();
      expect(_input('提交延迟'), findsNothing);
      await tester.tap(find.text('自动提交'));
      await tester.pump();
      expect(tester.widget<TextField>(_input('提交延迟')).controller!.text, '30');
      await tester.enterText(_input('单选 / 判断答案'), 'A');
      await tester.enterText(_input('提交延迟'), '0');
      await _reveal(tester, find.text('保存设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(find.text('提交延迟请输入 1–3600 秒'), findsOneWidget);
      expect(controller.saves, 0);
      await _reveal(tester, _input('提交延迟'));
      await tester.pumpAndSettle();
      await tester.enterText(_input('提交延迟'), '45');
      expect(controller.settings.autoSubmitDelaySeconds, 30);
      await _reveal(tester, find.text('保存设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(controller.saved!.autoSubmitDelaySeconds, 45);
      await _close(tester, controller);
    },
  );

  testWidgets(
    'pending and failed saves keep the effective settings unchanged',
    (tester) async {
      final gate = Completer<void>();
      final controller = _Controller(_Ai())..pendingSave = gate;
      await _show(tester, controller);
      await tester.tap(find.text('自动答题'));
      await tester.pump();
      await tester.enterText(_input('单选 / 判断答案'), 'A');
      await _reveal(tester, find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(find.text('保存中…'), findsOneWidget);
      expect(controller.settings.autoAnswer, isFalse);
      expect(controller.settings.fixedSingleAnswer, defaultFixedSingleAnswer);
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
      await tester.enterText(_input('单选 / 判断答案'), 'A');
      expect(controller.settings.autoAnswer, isFalse);
      expect(controller.settings.autoSubmit, isFalse);
      expect(controller.settings.autoEnter, isFalse);
      await _reveal(tester, find.text('保存设置'));
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
      expect(find.text('github.com/furryzirui/ykt_helper'), findsOneWidget);
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
      await _reveal(tester, _input('提示词'));
      await tester.enterText(_input('提示词'), '只输出结果：{question}');
      expect(controller.settings.customPrompt, defaultAiPrompt);
      await _reveal(tester, find.text('保存设置'));
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
      await _reveal(tester, find.text('保存设置'));
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
    await _reveal(tester, find.text('保存设置'));
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
      expect(_input('单选 / 判断答案'), findsOneWidget);
      await tester.tap(find.text('自定义 AI'));
      await tester.pump(const Duration(milliseconds: 501));
      ai.requests[1].response.complete(['current-model']);
      await tester.pump();
      await tester.pump();
      expect(find.text('current-model'), findsOneWidget);
      await _reveal(tester, find.byTooltip('刷新模型列表'));
      await tester.tap(find.byTooltip('刷新模型列表'));
      await tester.pump(const Duration(milliseconds: 1));
      expect(ai.requests, hasLength(3));
      ai.requests[2].response.completeError(const ApiFailure('模型列表获取失败'));
      await tester.pump();
      await _reveal(tester, find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pump();
      expect(controller.saves, 0);
      expect(find.text('请先获取并选择当前 AI 服务的模型'), findsOneWidget);
      await _close(tester, controller);
    },
  );
}
