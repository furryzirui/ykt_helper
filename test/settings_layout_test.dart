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

Future<void> _capture(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  if (!_screenshots) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('.workspace-bootstrap/qa-1.0.1');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
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
        await _reveal(tester, find.widgetWithText(FilledButton, '保存设置'));
        expect(
          tester.getSize(find.widgetWithText(FilledButton, '保存设置')).width,
          closeTo(width, .1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }
}
