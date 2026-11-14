import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import 'package:ykt_helper/services/file_export.dart';

void main() {
  test(
    'Windows delivery uses Save dialog and writes the selected path',
    () async {
      final directory = await Directory.systemTemp.createTemp('ykt-export-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/generated.zip')
        ..writeAsBytesSync([1, 2, 3]);
      final destination = '${directory.path}/saved.zip';
      var pickerCalls = 0;
      final result = FileExport(
        isWindows: () => true,
        pickSaveLocation:
            ({suggestedName, acceptedTypeGroups = const []}) async {
              pickerCalls++;
              expect(suggestedName, '课件.zip');
              expect(acceptedTypeGroups.single.extensions, ['zip']);
              return FileSaveLocation(destination);
            },
        share: (_) async => throw StateError('share must not be called'),
      );
      await result.deliver(
        source,
        suggestedName: '课件.zip',
        mimeType: 'application/zip',
        extension: 'zip',
      );
      expect(pickerCalls, 1);
      expect(await File(destination).readAsBytes(), [1, 2, 3]);
    },
  );

  test('cancelled Windows Save dialog does not share or write', () async {
    final directory = await Directory.systemTemp.createTemp('ykt-export-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/generated.txt')
      ..writeAsStringSync('log');
    var shared = false;
    final result = FileExport(
      isWindows: () => true,
      pickSaveLocation:
          ({suggestedName, acceptedTypeGroups = const []}) async => null,
      share: (_) async {
        shared = true;
        return const ShareResult('', ShareResultStatus.success);
      },
    );
    expect(
      result.deliver(
        source,
        suggestedName: '日志.txt',
        mimeType: 'text/plain',
        extension: 'txt',
      ),
      throwsA(isA<Exception>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(shared, isFalse);
    expect(await File('${directory.path}/日志.txt').exists(), isFalse);
  });

  test('mobile delivery invokes the share sheet with the anchor', () async {
    final directory = await Directory.systemTemp.createTemp('ykt-export-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/generated.pptx')
      ..writeAsBytesSync([9]);
    ShareParams? sent;
    final result = FileExport(
      isWindows: () => false,
      share: (params) async {
        sent = params;
        return const ShareResult('', ShareResultStatus.success);
      },
      pickSaveLocation:
          ({suggestedName, acceptedTypeGroups = const []}) async =>
              throw StateError('picker must not be called'),
    );
    await result.deliver(
      source,
      suggestedName: '课件.pptx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      extension: 'pptx',
      sharePositionOrigin: const Rect.fromLTWH(1, 2, 3, 4),
    );
    expect(sent, isNotNull);
    expect(sent!.files!.single.path, source.path);
    expect(sent!.sharePositionOrigin, const Rect.fromLTWH(1, 2, 3, 4));
  });
}
