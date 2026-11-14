import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';

class SlideExporter {
  final Future<Uint8List> Function(String url) loadImage;
  SlideExporter(this.loadImage);
  static String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static String _safeName(String value) {
    final result = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .trim();
    return result.isEmpty
        ? '课件'
        : result.substring(0, result.length.clamp(0, 80));
  }

  static String _extension(Uint8List bytes) {
    if (bytes.length > 3 && bytes[0] == 255 && bytes[1] == 216) return 'jpg';
    if (bytes.length > 8 && bytes[0] == 137 && bytes[1] == 80) return 'png';
    throw const ApiFailure('导出仅支持 PNG / JPEG 课件图片');
  }

  Future<File> saveSlide(Slide slide) async {
    final bytes = await loadImage(slide.imageUrl);
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/exports',
    );
    await dir.create(recursive: true);
    return File(
      '${dir.path}/第${slide.index + 1}页-${DateTime.now().millisecondsSinceEpoch}.${_extension(bytes)}',
    ).writeAsBytes(bytes, flush: true);
  }

  Future<File> export(
    Presentation presentation, {
    required bool pptx,
    void Function(int done, int total)? progress,
    bool Function()? cancelled,
  }) async {
    if (presentation.slides.isEmpty) throw const ApiFailure('没有可导出的课件页');
    final images = <Uint8List>[];
    var total = 0;
    for (var i = 0; i < presentation.slides.length; i++) {
      if (cancelled?.call() == true) throw const ApiFailure('已取消导出');
      final bytes = await loadImage(presentation.slides[i].imageUrl);
      _extension(bytes);
      total += bytes.length;
      if (total > 200 * 1024 * 1024) {
        throw const ApiFailure('课件超过 200 MB，请分批保存');
      }
      images.add(bytes);
      progress?.call(i + 1, presentation.slides.length);
    }
    final archive = pptx ? await buildPptx(presentation, images) : Archive();
    if (!pptx) {
      for (var i = 0; i < images.length; i++) {
        archive.addFile(
          ArchiveFile(
            '第${(presentation.slides[i].index + 1).toString().padLeft(3, '0')}页.${_extension(images[i])}',
            images[i].length,
            images[i],
          ),
        );
      }
    }
    if (cancelled?.call() == true) throw const ApiFailure('已取消导出');
    final directory = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/exports',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/${_safeName(presentation.title)}-${DateTime.now().millisecondsSinceEpoch}.${pptx ? 'pptx' : 'zip'}',
    );
    return file.writeAsBytes(ZipEncoder().encode(archive), flush: true);
  }

  static Future<Archive> buildPptx(
    Presentation presentation,
    List<Uint8List> images,
  ) async {
    if (images.isEmpty || images.length != presentation.slides.length) {
      throw const ApiFailure('课件图片数量不匹配');
    }
    final archive = Archive();
    void xml(String path, String value) {
      final bytes = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>$value',
      );
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    const p = 'http://schemas.openxmlformats.org/presentationml/2006/main';
    const a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
    const r =
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const rel = 'http://schemas.openxmlformats.org/package/2006/relationships';
    const group =
        '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';
    final codec = await ui.instantiateImageCodec(images.first);
    final frame = await codec.getNextFrame();
    const width = 12192000;
    final height = (width * frame.image.height / frame.image.width).round();
    frame.image.dispose();
    codec.dispose();
    final overrides = <String>[
      '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>',
      '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>',
      '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>',
      '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
    ];
    for (var i = 1; i <= images.length; i++) {
      overrides.add(
        '<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>',
      );
    }
    xml(
      '[Content_Types].xml',
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="png" ContentType="image/png"/>${overrides.join()}</Types>',
    );
    xml(
      '_rels/.rels',
      '<Relationships xmlns="$rel"><Relationship Id="rId1" Type="$r/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>',
    );
    xml(
      'docProps/core.xml',
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>${_xml(presentation.title)}</dc:title><dc:creator>ykt_helper</dc:creator></cp:coreProperties>',
    );
    xml(
      'ppt/presentation.xml',
      '<p:presentation xmlns:p="$p" xmlns:a="$a" xmlns:r="$r"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster"/></p:sldMasterIdLst><p:sldIdLst>${List.generate(images.length, (i) => '<p:sldId id="${256 + i}" r:id="rId${i + 1}"/>').join()}</p:sldIdLst><p:sldSz cx="$width" cy="$height"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
    );
    xml(
      'ppt/_rels/presentation.xml.rels',
      '<Relationships xmlns="$rel"><Relationship Id="rIdMaster" Type="$r/slideMaster" Target="slideMasters/slideMaster1.xml"/>${List.generate(images.length, (i) => '<Relationship Id="rId${i + 1}" Type="$r/slide" Target="slides/slide${i + 1}.xml"/>').join()}</Relationships>',
    );
    xml(
      'ppt/slideMasters/slideMaster1.xml',
      '<p:sldMaster xmlns:p="$p" xmlns:a="$a" xmlns:r="$r"><p:cSld><p:spTree>$group</p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>',
    );
    xml(
      'ppt/slideMasters/_rels/slideMaster1.xml.rels',
      '<Relationships xmlns="$rel"><Relationship Id="rId1" Type="$r/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="$r/theme" Target="../theme/theme1.xml"/></Relationships>',
    );
    xml(
      'ppt/slideLayouts/slideLayout1.xml',
      '<p:sldLayout xmlns:p="$p" xmlns:a="$a" xmlns:r="$r" type="blank" preserve="1"><p:cSld name="空白"><p:spTree>$group</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>',
    );
    xml(
      'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      '<Relationships xmlns="$rel"><Relationship Id="rId1" Type="$r/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>',
    );
    final colors = {
      'dk1': '000000',
      'lt1': 'FFFFFF',
      'dk2': '1F2937',
      'lt2': 'F3F4F6',
      'accent1': '2563EB',
      'accent2': '16A34A',
      'accent3': 'F59E0B',
      'accent4': 'DC2626',
      'accent5': '7C3AED',
      'accent6': '0891B2',
      'hlink': '0563C1',
      'folHlink': '954F72',
    };
    final fills = List.filled(
      3,
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>',
    ).join();
    final lines = List.filled(
      3,
      '<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>',
    ).join();
    xml(
      'ppt/theme/theme1.xml',
      '<a:theme xmlns:a="$a" name="雨课堂"><a:themeElements><a:clrScheme name="默认">${colors.entries.map((e) => '<a:${e.key}><a:srgbClr val="${e.value}"/></a:${e.key}>').join()}</a:clrScheme><a:fontScheme name="默认"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface="Microsoft YaHei"/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface="Microsoft YaHei"/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="默认"><a:fillStyleLst>$fills</a:fillStyleLst><a:lnStyleLst>$lines</a:lnStyleLst><a:effectStyleLst>${List.filled(3, '<a:effectStyle><a:effectLst/></a:effectStyle>').join()}</a:effectStyleLst><a:bgFillStyleLst>$fills</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>',
    );
    for (var i = 0; i < images.length; i++) {
      final n = i + 1;
      final extension = _extension(images[i]);
      archive.addFile(
        ArchiveFile(
          'ppt/media/image$n.$extension',
          images[i].length,
          images[i],
        ),
      );
      xml(
        'ppt/slides/slide$n.xml',
        '<p:sld xmlns:p="$p" xmlns:a="$a" xmlns:r="$r"><p:cSld><p:spTree>$group<p:pic><p:nvPicPr><p:cNvPr id="2" name="第${presentation.slides[i].index + 1}页"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$width" cy="$height"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>',
      );
      xml(
        'ppt/slides/_rels/slide$n.xml.rels',
        '<Relationships xmlns="$rel"><Relationship Id="rIdImage" Type="$r/image" Target="../media/image$n.$extension"/><Relationship Id="rIdLayout" Type="$r/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>',
      );
    }
    return archive;
  }
}
