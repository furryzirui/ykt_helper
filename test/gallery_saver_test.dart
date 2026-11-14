import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/gallery_saver.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
);

class ImageController extends AppController {
  ImageController() : super(startTimers: false, connectSockets: false);

  @override
  Future<Uint8List> loadImage(String url) async => png;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ykt_helper/gallery');
  const saver = GallerySaver();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'writes original image bytes and correct media metadata to gallery channel',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      await saver.saveImage(png, name: '课件第1页');
      final args = calls.single.arguments as Map;
      expect(calls.single.method, 'saveImage');
      expect(args['bytes'], orderedEquals(png));
      expect(args['name'], '课件第1页.png');
      expect(args['mimeType'], 'image/png');
    },
  );

  test(
    'native permission rejection is propagated without reporting success',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'permission_denied',
          message: '未授予相册存储权限',
        );
      });
      await expectLater(
        saver.saveImage(png, name: '课件'),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.message,
            'message',
            contains('未授予'),
          ),
        ),
      );
    },
  );

  test('native false response is not treated as a saved image', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    await expectLater(
      saver.saveImage(png, name: '课件'),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.message,
          'message',
          contains('未确认'),
        ),
      ),
    );
  });

  test(
    'unsupported platform and invalid image do not invoke native storage',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return true;
      });
      await expectLater(
        saver.saveImage(Uint8List.fromList([137, 80, 1]), name: '课件'),
        throwsA(isA<ApiFailure>()),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(
        saver.saveImage(png, name: '课件'),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'batch waits for each native write, skips imageless pages and keeps page numbers',
    () async {
      final firstWrite = Completer<void>();
      final releaseFirst = Completer<bool>();
      final loaded = <String>[];
      final names = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        names.add((call.arguments as Map)['name'] as String);
        if (names.length == 1) {
          firstWrite.complete();
          return releaseFirst.future;
        }
        return true;
      });
      final operation = saver.saveSlides(
        const [
          Slide(id: '1', index: 0, imageUrl: 'https://example.com/1'),
          Slide(id: '2', index: 1, imageUrl: ''),
          Slide(id: '3', index: 2, imageUrl: 'https://example.com/3'),
        ],
        (url) async {
          loaded.add(url);
          return png;
        },
      );
      await firstWrite.future;
      expect(loaded, ['https://example.com/1']);
      releaseFirst.complete(true);
      expect(await operation, 2);
      expect(loaded, ['https://example.com/1', 'https://example.com/3']);
      expect(names.first, contains('第1页.png'));
      expect(names.last, contains('第3页.png'));
    },
  );

  test(
    'batch failure preserves exact saved count and does not silently retry or skip',
    () async {
      var writes = 0;
      final loaded = <String>[];
      messenger.setMockMethodCallHandler(channel, (_) async {
        writes++;
        return true;
      });
      final operation = saver.saveSlides(
        const [
          Slide(id: '1', index: 0, imageUrl: 'https://example.com/1'),
          Slide(id: '2', index: 1, imageUrl: 'https://example.com/2'),
          Slide(id: '3', index: 2, imageUrl: 'https://example.com/3'),
        ],
        (url) async {
          loaded.add(url);
          if (url.endsWith('/2')) throw const ApiFailure('图片下载失败');
          return png;
        },
      );
      await expectLater(
        operation,
        throwsA(
          isA<ApiFailure>()
              .having((error) => error.message, 'saved count', contains('1/3'))
              .having(
                (error) => error.message,
                'failed page',
                contains('第 2 页'),
              ),
        ),
      );
      expect(writes, 1);
      expect(loaded.length, 2);
    },
  );

  test(
    'single and all-page controller actions save to gallery without opening share',
    () async {
      var writes = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        writes++;
        return true;
      });
      final controller = ImageController();
      addTearDown(controller.dispose);
      const slide = Slide(
        id: 's',
        index: 0,
        imageUrl: 'https://example.com/image',
      );
      await controller.saveSlide(slide);
      expect(await controller.saveSlidesToGallery([slide, slide]), 2);
      expect(writes, 3);
      // No share plugin is registered: opening a share sheet would fail this test.
    },
  );
}
