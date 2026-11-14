import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/slide_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'image PPTX contains complete OpenXML slides and image relationships',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
      );
      const presentation = Presentation(
        id: 'p',
        title: '标题 & 课件',
        slides: [
          Slide(id: 's1', index: 0, imageUrl: ''),
          Slide(id: 's2', index: 2, imageUrl: ''),
        ],
      );
      final archive = await SlideExporter.buildPptx(presentation, [png, png]);
      final reloaded = ZipDecoder().decodeBytes(ZipEncoder().encode(archive));
      expect(reloaded.findFile('ppt/slides/slide1.xml'), isNotNull);
      expect(reloaded.findFile('ppt/slides/slide2.xml'), isNotNull);
      expect(reloaded.findFile('ppt/media/image2.png'), isNotNull);
      final relationships = utf8.decode(
        reloaded.findFile('ppt/slides/_rels/slide2.xml.rels')!.content,
      );
      expect(relationships, contains('../media/image2.png'));
      expect(relationships, contains('../slideLayouts/slideLayout1.xml'));
      expect(
        utf8.decode(reloaded.findFile('docProps/core.xml')!.content),
        contains('标题 &amp; 课件'),
      );
      expect(
        utf8.decode(reloaded.findFile('ppt/slides/slide2.xml')!.content),
        contains('第3页'),
      );
    },
  );
}
