import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';

/// Platform boundary for writing images to the user's photo library.
class GallerySaver {
  final MethodChannel channel;
  final Future<String?> Function()? directoryPicker;
  const GallerySaver({
    this.channel = const MethodChannel('ykt_helper/gallery'),
    this.directoryPicker,
  });

  Future<void> saveImage(Uint8List bytes, {required String name}) async {
    if (kIsWeb ||
        ![
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.windows,
        ].contains(defaultTargetPlatform)) {
      throw const ApiFailure('当前平台暂不支持保存到系统相册');
    }
    final extension = _extension(bytes);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final directory = await _pickDirectory();
      await File(
        '${directory.path}/$name.$extension',
      ).writeAsBytes(bytes, flush: true);
      return;
    }
    try {
      final saved = await channel.invokeMethod<bool>('saveImage', {
        'bytes': bytes,
        'name': '$name.$extension',
        'mimeType': extension == 'png' ? 'image/png' : 'image/jpeg',
      });
      if (saved != true) throw const ApiFailure('系统未确认图片已保存到相册');
    } on PlatformException catch (error) {
      throw ApiFailure(error.message ?? '保存到系统相册失败');
    } on MissingPluginException {
      throw const ApiFailure('当前平台暂不支持保存到系统相册');
    }
  }

  String _extension(Uint8List bytes) {
    final png =
        bytes.length >= 8 &&
        listEquals(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if (!png && !jpeg) throw const ApiFailure('保存到相册仅支持 PNG / JPEG 课件图片');
    return png ? 'png' : 'jpg';
  }

  Future<Directory> _pickDirectory() async {
    final path = await (directoryPicker?.call() ?? getDirectoryPath());
    if (path == null) throw const ApiFailure('已取消保存');
    return Directory(path);
  }

  Future<int> saveSlides(
    List<Slide> slides,
    Future<Uint8List> Function(String url) loadImage,
  ) async {
    final images = slides.where((slide) => slide.imageUrl.isNotEmpty).toList();
    if (images.isEmpty) throw const ApiFailure('没有可保存的课件图片');
    final directory = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
        ? await _pickDirectory()
        : null;
    var saved = 0;
    final batch = DateTime.now().microsecondsSinceEpoch;
    for (final slide in images) {
      try {
        // Fetch and write one page at a time to avoid retaining a full deck.
        final bytes = await loadImage(slide.imageUrl);
        final name = 'ykt_helper-$batch-第${slide.index + 1}页';
        if (directory != null) {
          final extension = _extension(bytes);
          await File(
            '${directory.path}/$name.$extension',
          ).writeAsBytes(bytes, flush: true);
        } else {
          await saveImage(bytes, name: name);
        }
        saved++;
      } catch (error) {
        throw ApiFailure(
          '已保存 $saved/${images.length} 页到相册，第 ${slide.index + 1} 页保存失败：$error',
        );
      }
    }
    return saved;
  }
}
