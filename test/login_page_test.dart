import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart' hide RainServer;
import 'package:ykt_helper/domain/rain_server.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/login_page.dart';

class _LoginApi extends RainApi {
  final qr = Completer<Json>();
  int cancelled = 0, polls = 0, creates = 0;
  _LoginApi({super.server});
  @override
  Future<Json> createQr() {
    creates++;
    return qr.future;
  }

  @override
  Future<bool> pollQr(String token) async {
    polls++;
    return false;
  }

  @override
  void cancelQr() {
    cancelled++;
  }

  @override
  Future<void> logout() async {}
}

class _Store implements KeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  for (final scale in [1.0, 1.5]) {
    testWidgets('三种登录方式并列，切换后迟到二维码不会恢复 $scale', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final api = _LoginApi();
      final controller = AppController(
        api: api,
        store: _Store(),
        startTimers: false,
        connectSockets: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: rainTheme(Brightness.light),
          home: LoginPage(controller: controller),
        ),
      );
      expect(find.byKey(const ValueKey('login-server')), findsOneWidget);
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(api.creates, 0);
      await tester.tap(find.byKey(const ValueKey('confirm-login-server')));
      await tester.pump();
      expect(api.creates, 1);
      final qr = find.text('二维码'),
          sms = find.text('验证码'),
          password = find.text('账号密码');
      expect(tester.getCenter(qr).dy, tester.getCenter(sms).dy);
      expect(tester.getCenter(sms).dy, tester.getCenter(password).dy);
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.tap(sms);
      await tester.pump();
      expect(_field('手机号'), findsOneWidget);
      expect(_field('短信验证码'), findsOneWidget);
      await tester.enterText(_field('短信验证码'), '123456');
      api.qr.complete({
        'token': 'obsolete',
        'qrContent': 'https://example.com/old',
      });
      await tester.pump();
      expect(api.polls, 0);
      expect(find.text('扫描二维码并确认登录'), findsNothing);
      await tester.tap(password);
      await tester.pump();
      expect(_field('手机号或邮箱'), findsOneWidget);
      final secret = tester.widget<TextField>(_field('密码'));
      expect(secret.obscureText, isTrue);
      expect(secret.controller!.text, isEmpty);
      expect(api.cancelled, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('更换服务端后旧二维码不能恢复，三种登录方式共用所选端', (tester) async {
    final store = _Store();
    final standard = _LoginApi();
    final selectedApis = <RainServer, _LoginApi>{};
    final controller = AppController(
      api: standard,
      apiFactory: (server) =>
          selectedApis.putIfAbsent(server, () => _LoginApi(server: server)),
      store: store,
      startTimers: false,
      connectSockets: false,
    );
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('confirm-login-server')));
    await tester.pump();
    expect(standard.creates, 1);
    await tester.tap(find.byKey(const ValueKey('change-login-server')));
    await tester.pump();
    expect(find.byType(SegmentedButton<int>), findsNothing);
    tester
        .widget<DropdownButtonFormField<RainServer>>(
          find.byKey(const ValueKey('login-server')),
        )
        .onChanged!(RainServer.hetang);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-login-server')));
    await tester.pump();
    final selected = selectedApis[RainServer.hetang]!;
    expect(controller.server, RainServer.hetang);
    expect(store.values['rainServer'], RainServer.hetang.name);
    expect(selected.creates, 1);
    standard.qr.complete({
      'token': 'old-server-token',
      'qrContent': 'https://example.com/old',
    });
    await tester.pump();
    expect(standard.polls, 0);
    expect(find.text('扫描二维码并确认登录'), findsNothing);
    await tester.tap(find.text('验证码'));
    await tester.pump();
    expect(_field('手机号'), findsOneWidget);
    expect(identical(controller.api, selected), isTrue);
    await tester.tap(find.text('账号密码'));
    await tester.pump();
    expect(_field('手机号或邮箱'), findsOneWidget);
    expect(identical(controller.api, selected), isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
