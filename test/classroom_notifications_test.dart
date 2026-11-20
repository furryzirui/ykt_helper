import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/services/classroom_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('test/classroom_notifications');
  const notifications = ClassroomNotifications(channel: channel);
  final calls = <MethodCall>[];

  Future<bool> show({String key = 'lesson:problem:manual'}) =>
      notifications.show(
        key: key,
        title: '课堂提醒',
        body: '答案已填充，请确认提交',
        lessonId: 'lesson',
        problemId: 'problem',
      );

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'show' ? true : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'show sends an explicit reminder identity through the injected channel',
    () async {
      expect(await show(), true);
      expect(calls.single.method, 'show');
      expect(calls.single.arguments, {
        'key': 'lesson:problem:manual',
        'title': '课堂提醒',
        'body': '答案已填充，请确认提交',
        'lessonId': 'lesson',
        'problemId': 'problem',
      });
    },
  );

  for (final reply in [false, null, 'unexpected']) {
    test('non-success native response $reply is skipped', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => reply);
      expect(await show(), false);
    });
  }

  test('empty identity is refused before invoking the platform', () async {
    expect(await show(key: ''), false);
    expect(calls, isEmpty);
  });

  test(
    'cancel only carries its reminder key and cancelAll uses this channel',
    () async {
      await notifications.cancel('lesson:problem:manual');
      await notifications.cancelAll();
      expect(calls.map((call) => call.method), ['cancel', 'cancelAll']);
      expect(calls.first.arguments, {'key': 'lesson:problem:manual'});
      expect(calls.last.arguments, isNull);
    },
  );

  for (final missing in [false, true]) {
    test(
      'missing=$missing platform failures never interrupt classroom work',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async {
          if (missing) throw MissingPluginException();
          throw PlatformException(code: 'denied');
        });
        expect(await show(), false);
        await notifications.cancel('key');
        await notifications.cancelAll();
      },
    );
  }
}
