import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/ui/widgets.dart';

void main() {
  for (final dimensions in [const Size(160, 90), const Size(90, 160)]) {
    testWidgets('课件按实际比例 $dimensions 显示，不增加上下留白', (tester) async {
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(
          recorder,
        ).drawRect(Offset.zero & dimensions, Paint()..color = Colors.teal);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          dimensions.width.toInt(),
          dimensions.height.toInt(),
        );
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        picture.dispose();
        image.dispose();
        return data!.buffer.asUint8List();
      });
      final provider = MemoryImage(bytes!);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: SlideImage(
                  const Slide(id: 'ratio', index: 0, imageUrl: ''),
                  imageProvider: provider,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(provider, tester.element(find.byType(SlideImage))),
      );
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byType(SlideImage));
      expect(size.width, 320);
      expect(
        size.height,
        closeTo(320 * dimensions.height / dimensions.width, .1),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
