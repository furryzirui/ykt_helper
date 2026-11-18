import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/services/app_autostart.dart';

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

  bool active = false;
  int calls = 0;

  @override
  bool get supported => true;

  @override
  bool get enabled => active;

  @override
  bool get busy => false;

  @override
  Future<bool> setEnabled(bool enabled) async {
    calls++;
    active = enabled;
    return true;
  }
}

class _Api extends RainApi {
  @override
  Future<void> logout() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AppAutostart.channel,
          (MethodCall _) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppAutostart.channel, null);
  });

  test(
    'auto-start setting is persisted without a system service preference',
    () {
      final settings = AppSettings(autoStartService: true, autoAnswer: true);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.autoStartService, isTrue);
      expect(settings.toJson(), isNot(contains('systemService')));
    },
  );

  test(
    'auto-start launches only with automation and manual off wins',
    () async {
      final runtime = _Background();
      final controller =
          AppController(
              api: _Api(),
              store: _Store(),
              background: runtime,
              startTimers: false,
              connectSockets: false,
            )
            ..account = const Account(id: 'u', name: '测试')
            ..settings = AppSettings(autoAnswer: true, autoStartService: true);
      addTearDown(controller.dispose);

      await controller.retryBackground();
      expect(runtime.active, isTrue);

      await controller.setSystemService(false);
      expect(runtime.active, isFalse);
      await controller.retryBackground();
      expect(runtime.active, isFalse);
      controller.settings = AppSettings(autoEnter: true);
      await controller.retryBackground();
      expect(runtime.active, isFalse);

      await controller.setSystemService(true);
      expect(runtime.active, isTrue);
      controller.settings = AppSettings();
      await controller.retryBackground();
      expect(runtime.active, isFalse);
      controller.settings = AppSettings(autoEnter: true);
      await controller.retryBackground();
      expect(runtime.active, isFalse);
    },
  );

  test('manual service switch cannot enable without automation', () async {
    final runtime = _Background();
    final controller = AppController(
      api: _Api(),
      store: _Store(),
      background: runtime,
      startTimers: false,
      connectSockets: false,
    )..account = const Account(id: 'u', name: '测试');
    addTearDown(controller.dispose);

    await expectLater(
      controller.setSystemService(true),
      throwsA(isA<ApiFailure>()),
    );
    expect(runtime.active, isFalse);
  });
}
