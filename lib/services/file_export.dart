import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/models.dart';

typedef SaveLocationPicker =
    Future<FileSaveLocation?> Function({
      String? suggestedName,
      List<XTypeGroup> acceptedTypeGroups,
    });

typedef ShareFile = Future<ShareResult> Function(ShareParams params);

/// Delivers generated files using the platform's intended file workflow.
///
/// Windows has no useful consumer share target for exported course files, so
/// it writes directly to the path selected in the native Save dialog. Mobile
/// platforms continue using the system share sheet, including iPad's anchor.
class FileExport {
  final SaveLocationPicker _pickSaveLocation;
  final ShareFile _share;
  final bool Function() _isWindows;

  FileExport({
    SaveLocationPicker? pickSaveLocation,
    ShareFile? share,
    bool Function()? isWindows,
  }) : _pickSaveLocation = pickSaveLocation ?? _defaultPicker,
       _share = share ?? _defaultShare,
       _isWindows = isWindows ?? _defaultIsWindows;

  static Future<FileSaveLocation?> _defaultPicker({
    String? suggestedName,
    List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  }) => getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: acceptedTypeGroups,
  );

  static Future<ShareResult> _defaultShare(ShareParams params) =>
      SharePlus.instance.share(params);

  static bool _defaultIsWindows() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<void> deliver(
    File file, {
    required String suggestedName,
    required String mimeType,
    required String extension,
    Rect? sharePositionOrigin,
  }) async {
    if (!await file.exists()) throw const ApiFailure('导出文件不存在');
    if (_isWindows()) {
      final location = await _pickSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: [
          XTypeGroup(
            label: mimeType,
            extensions: [extension],
            mimeTypes: [mimeType],
          ),
        ],
      );
      if (location == null) throw const ApiFailure('已取消导出');
      await XFile(file.path, mimeType: mimeType).saveTo(location.path);
      return;
    }
    await _share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType)],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}
