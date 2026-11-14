import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/app_permissions.dart';
import 'package:ykt_helper/ui/about_page.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/automation_page.dart';
import 'package:ykt_helper/ui/permissions_page.dart';
import 'package:ykt_helper/ui/settings_page.dart';
import 'package:ykt_helper/ui/settings_widgets.dart';

const _screenshots = bool.fromEnvironment('GENERATE_SCREENSHOTS');
final _boundary = GlobalKey();

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Ai extends AiAnswerService {
  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) async => ['vision-model'];
}

class _StatusAi extends AiAnswerService {
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

class _StatusController extends AppController {
  String? saveError;
  Completer<void>? pendingSave;
  int saves = 0;

  _StatusController({AiAnswerService? ai})
    : super(
        store: _Store(),
        ai: ai ?? _Ai(),
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
    settings = AppSettings(autoAnswer: true);
  }

  @override
  Future<void> saveSettings([AppSettings? next]) async {
    saves++;
    final candidate = AppSettings.fromJson((next ?? settings).toJson());
    await pendingSave?.future;
    if (saveError != null) throw ApiFailure(saveError!);
    settings = candidate;
    notifyListeners();
  }
}

class _Permissions extends AppPermissions {
  @override
  Future<List<AppPermissionState>> check() async => [
    for (final permission in AppPermission.values)
      AppPermissionState(
        permission: permission,
        status: permission == AppPermission.photos
            ? PermissionStatus.notRequired
            : PermissionStatus.granted,
      ),
  ];
}

class _Controller extends AppController {
  _Controller()
    : super(
        store: _Store(),
        ai: _Ai(),
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
    account = const Account(id: 'user', name: '测试学生', school: '大学');
    settings = AppSettings(
      autoStartService: false,
      autoEnter: true,
      autoAnswer: true,
      autoSubmit: true,
      answerMode: AnswerMode.ai,
      baseUrl: 'https://offline.invalid/v1',
      apiKey: 'offline-only',
      model: 'vision-model',
      slideScope: SlideScope.currentAndNext,
    );
  }
}

Future<void> _mount(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: rainTheme(Brightness.light),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  String folder = 'qa-1.0.1',
}) async {
  expect(tester.takeException(), isNull, reason: name);
  if (!_screenshots) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('.workspace-bootstrap/$folder');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _openStatusPage(
  WidgetTester tester,
  AppController controller,
) async {
  await _mount(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
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
  expect(find.byType(BackButton), findsOneWidget);
}

void _checkStatusGeometry(
  WidgetTester tester,
  Size size,
  Rect appBar,
  Rect firstSetting,
) {
  final status = find.byKey(const ValueKey('automation-status'));
  final title = find.descendant(
    of: find.byType(AppBar),
    matching: find.text('自动化'),
  );
  final statusText = tester.widget<Text>(status);
  final statusRect = tester.getRect(status);
  final titleRect = tester.getRect(title);
  expect(statusText.maxLines, 1);
  expect(statusText.overflow, TextOverflow.ellipsis);
  if (statusText.data?.isNotEmpty == true) {
    expect(statusRect.width, greaterThan(0));
  }
  expect(statusRect.left, greaterThanOrEqualTo(titleRect.right));
  expect(statusRect.right, lessThanOrEqualTo(size.width));
  expect(statusRect.top, greaterThanOrEqualTo(appBar.top));
  expect(statusRect.bottom, lessThanOrEqualTo(appBar.bottom));
  expect(titleRect.width, greaterThan(48));
  expect(tester.getRect(find.byType(AppBar)), appBar);
  expect(tester.widget<AppBar>(find.byType(AppBar)).bottom, isNull);
  expect(
    tester.getRect(find.byKey(const ValueKey('auto-start-service'))),
    firstSetting,
  );
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(find.byIcon(Icons.sync_rounded), findsNothing);
  expect(tester.takeException(), isNull);
}

void _checkCardWidths(WidgetTester tester, double expected) {
  final cards = find.descendant(
    of: find.byType(SettingsList),
    matching: find.byType(Card),
  );
  expect(cards, findsWidgets);
  for (final card in cards.evaluate()) {
    expect(
      tester
          .getSize(
            find.byElementPredicate((element) => identical(element, card)),
          )
          .width,
      closeTo(expected, .1),
    );
  }
  for (final tile in tester.widgetList<SettingTile>(find.byType(SettingTile))) {
    expect(tile.description.trim(), isNotEmpty);
    expect(tile.description, isNot(contains('\n')));
  }
}

Future<void> _reveal(
  WidgetTester tester,
  Finder target, {
  double delta = 200,
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
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_screenshots) return;
    final font = File(
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc',
    );
    if (await font.exists()) {
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
    }
    final config = File('.dart_tool/package_config.json');
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.cast<Map>().firstWhere(
      (package) => package['name'] == 'flutter',
    );
    final flutterRoot = Directory.fromUri(
      config.absolute.uri.resolve(flutter['rootUri'] as String),
    ).uri;
    final icons = File.fromUri(
      flutterRoot.resolve(
        '../../bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      ),
    );
    if (await icons.exists()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
  });
  for (final size in [
    const Size(360, 800),
    const Size(800, 400),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.5]) {
      final suffix = '${size.width.toInt()}x${size.height.toInt()}-$scale';
      testWidgets('自动保存长状态保持标题和正文位置 $suffix', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final controller = _StatusController();
        await _openStatusPage(tester, controller);
        final appBar = tester.getRect(find.byType(AppBar));
        final firstSetting = tester.getRect(
          find.byKey(const ValueKey('auto-start-service')),
        );
        final autoEnter = find.byKey(const ValueKey('auto-enter'));
        final status = find.byKey(const ValueKey('automation-status'));
        await tester.tap(autoEnter);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(status).data, '已自动保存');
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        await _capture(
          tester,
          'automation-status-saved-$suffix',
          folder: 'qa-automation-status',
        );

        const error = '无法保存自动化设置，请检查当前系统权限与本地存储状态后重试，原有设置仍然生效';
        final pending = Completer<void>();
        controller
          ..saveError = error
          ..pendingSave = pending;
        await tester.tap(autoEnter);
        await tester.pump();
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        pending.complete();
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(status).data, '未保存：$error');
        final errorSemantics = find.byKey(
          const ValueKey('automation-save-error'),
        );
        expect(
          find.descendant(of: find.byType(AppBar), matching: errorSemantics),
          findsOneWidget,
        );
        expect(find.byTooltip('未保存：$error，点击重试'), findsOneWidget);
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        await _capture(
          tester,
          'automation-status-save-error-$suffix',
          folder: 'qa-automation-status',
        );

        controller
          ..saveError = null
          ..pendingSave = null;
        await tester.tap(status);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(status).data, '已自动保存');
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        expect(controller.saves, 3);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });

      testWidgets('模型发现失败统一在右上角且不移动正文 $suffix', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final ai = _StatusAi();
        final controller = _StatusController(ai: ai)
          ..settings = AppSettings(
            autoAnswer: true,
            answerMode: AnswerMode.ai,
            baseUrl: 'https://offline.invalid/v1',
            apiKey: 'offline-only',
            model: 'vision-model',
          );
        await _openStatusPage(tester, controller);
        final appBar = tester.getRect(find.byType(AppBar));
        final firstSetting = tester.getRect(
          find.byKey(const ValueKey('auto-start-service')),
        );
        await tester.pump(const Duration(milliseconds: 501));
        expect(ai.requests, hasLength(1));
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        const error = '模型列表获取失败，请检查服务商地址与授权信息，确认模型服务可用后点击此处重试';
        ai.requests.single.completeError(const ApiFailure(error));
        await tester.pumpAndSettle();
        final status = find.byKey(const ValueKey('automation-status'));
        expect(tester.widget<Text>(status).data, '未保存：$error');
        expect(find.byTooltip('未保存：$error，点击重试'), findsOneWidget);
        expect(find.text(error), findsNothing);
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        await _capture(
          tester,
          'automation-status-model-error-$suffix',
          folder: 'qa-automation-status',
        );
        await tester.tap(status);
        await tester.pump(const Duration(milliseconds: 1));
        expect(ai.requests, hasLength(2));
        ai.requests.last.complete(['vision-model']);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('auto-enter')));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(status).data, '已自动保存');
        _checkStatusGeometry(tester, size, appBar, firstSetting);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }
  for (final size in [
    const Size(360, 800),
    const Size(1024, 768),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.5]) {
      final suffix = '${size.width.toInt()}x${size.height.toInt()}-$scale';
      testWidgets('设置备注与卡片宽度统一，无溢出 $suffix', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final controller = _Controller();
        final width = math.min(size.width - 32, 760.0);
        await _mount(
          tester,
          Scaffold(
            appBar: AppBar(title: const Text('设置')),
            body: SettingsPage(controller: controller),
          ),
        );
        expect(
          tester.getTopLeft(find.text('系统服务')).dy,
          greaterThan(tester.getTopLeft(find.text('测试学生')).dy),
        );
        expect(
          tester.getTopLeft(find.text('系统服务')).dy,
          lessThan(tester.getTopLeft(find.text('应用权限')).dy),
        );
        _checkCardWidths(tester, width);
        await _capture(tester, 'settings-menu-$suffix');
        await _reveal(tester, find.text('关于'));
        _checkCardWidths(tester, width);
        expect(tester.takeException(), isNull);

        await _mount(tester, const AboutPage());
        _checkCardWidths(tester, width);
        expect(find.textContaining('版本 '), findsOneWidget);
        await _capture(tester, 'settings-about-$suffix');
        await _reveal(tester, find.text('开源许可'));
        _checkCardWidths(tester, width);

        await _mount(tester, PermissionsPage(permissions: _Permissions()));
        expect(find.text('无需授权'), findsOneWidget);
        _checkCardWidths(tester, width);
        await _capture(tester, 'settings-permissions-$suffix');
        await _reveal(tester, find.text('电池优化'));
        _checkCardWidths(tester, width);

        await _mount(tester, AutomationPage(controller: controller));
        await tester.pump(const Duration(milliseconds: 501));
        await tester.pumpAndSettle();
        expect(find.text('保存设置'), findsNothing);
        expect(find.text('保存中…'), findsNothing);
        const automationKeys = [
          'auto-start-service',
          'app-auto-start',
          'auto-enter',
          'auto-answer',
          'auto-submit',
        ];
        for (final key in automationKeys) {
          expect(find.byKey(ValueKey(key)), findsOneWidget);
        }
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('app-auto-start')),
              )
              .onChanged,
          isNull,
        );
        for (var i = 0; i < automationKeys.length - 1; i++) {
          final previous = find.byKey(ValueKey(automationKeys[i]));
          final next = find.byKey(ValueKey(automationKeys[i + 1]));
          expect(
            tester.getBottomLeft(previous).dy,
            lessThanOrEqualTo(tester.getTopLeft(next).dy),
          );
          expect(tester.getSize(previous).width, tester.getSize(next).width);
        }
        for (final tile in tester.widgetList<SwitchListTile>(
          find.byType(SwitchListTile),
        )) {
          expect(tile.subtitle, isA<SettingDescription>());
          expect(
            (tile.subtitle as SettingDescription).text,
            isNot(contains('\n')),
          );
        }
        _checkCardWidths(tester, width);
        await _capture(tester, 'settings-automation-top-$suffix');
        final prompt = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '提示词',
        );
        await _reveal(tester, prompt);
        _checkCardWidths(tester, width);
        expect(find.text('{question} 自动替换为题目'), findsOneWidget);
        await _capture(tester, 'settings-automation-ai-$suffix');
        final slidePrompt = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '课件额外提示词',
        );
        await _reveal(tester, slidePrompt);
        expect(
          tester.widget<TextField>(slidePrompt).controller!.text,
          defaultSlidePrompt,
        );
        expect(find.text('发送课件时追加在原提示词之后'), findsOneWidget);
        _checkCardWidths(tester, width);
        expect(find.text('保存设置'), findsNothing);
        expect(find.text('保存中…'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.settings = AppSettings(autoAnswer: true, autoSubmit: true);
        await _mount(tester, AutomationPage(controller: controller));
        await _reveal(tester, find.byKey(const ValueKey('fixedSingle-A')));
        expect(find.byType(ChoiceChip), findsNWidgets(6));
        expect(find.byType(FilterChip), findsNWidgets(4));
        _checkCardWidths(tester, width);
        await _capture(tester, 'settings-fixed-options-$suffix');
        final subjective = find.byKey(const ValueKey('field-fixedSubjective'));
        await _reveal(tester, subjective);
        expect(find.text('每个空使用相同内容'), findsOneWidget);
        await _capture(tester, 'settings-fixed-subjective-$suffix');
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }
}
