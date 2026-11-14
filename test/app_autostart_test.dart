import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const autostart = AppAutostart();
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    messenger.setMockMethodCallHandler(AppAutostart.channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppAutostart.setForegroundListener(null);
    messenger.setMockMethodCallHandler(AppAutostart.channel, null);
  });

  test('configuration contains only persisted startup flags', () async {
    await autostart.configure(enabled: true, eligible: false);
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, {'enabled': true, 'eligible': false});
    await autostart.setSuspended(true);
    expect(calls.last.method, 'setSuspended');
    expect(calls.last.arguments, {'suspended': true});
  });

  test('iOS does not register startup or call native channels', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(autostart.supported, isFalse);
    await autostart.configure(enabled: true, eligible: true);
    await autostart.setSuspended(false);
    expect(await autostart.enabled(), isFalse);
    expect(await autostart.permissionStatus(), 'unsupported');
    expect(calls, isEmpty);
  });

  test(
    'Android OEM authorization is never inferred from app preference',
    () async {
      expect(await autostart.permissionStatus(), 'needsConfirmation');
      expect(calls, isEmpty);
    },
  );

  test('invalid native status fails instead of reporting enabled', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    messenger.setMockMethodCallHandler(
      AppAutostart.channel,
      (_) async => {'enabled': 'yes'},
    );
    await expectLater(autostart.enabled(), throwsA(isA<ApiFailure>()));
    await expectLater(autostart.permissionStatus(), throwsA(isA<ApiFailure>()));
  });

  test('write failures are surfaced without a false success', () async {
    messenger.setMockMethodCallHandler(AppAutostart.channel, (_) async {
      throw PlatformException(code: 'autostart_save_failed');
    });
    await expectLater(
      autostart.configure(enabled: true, eligible: true),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(autostart.setSuspended(true), throwsA(isA<ApiFailure>()));
  });

  test(
    'foreground callback is separate from background configuration',
    () async {
      var count = 0;
      AppAutostart.setForegroundListener(() => count++);
      final codec = const StandardMethodCodec();
      await messenger.handlePlatformMessage(
        AppAutostart.channel.name,
        codec.encodeMethodCall(const MethodCall('foreground')),
        (_) {},
      );
      expect(count, 1);
      expect(calls.map((call) => call.method), ['isForeground']);
    },
  );

  test(
    'foreground handshake recovers an Activity event preceding Dart startup',
    () async {
      var count = 0;
      messenger.setMockMethodCallHandler(
        AppAutostart.channel,
        (_) async => true,
      );
      AppAutostart.setForegroundListener(() => count++);
      await Future<void>.delayed(Duration.zero);
      expect(count, 1);
    },
  );
}
