import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_logs.dart';
import 'package:ykt_helper/services/file_export.dart';
import 'package:ykt_helper/ui/logs_page.dart';

class _Logs extends AppLogs {
  final Directory directory;
  _Logs(this.directory);
  @override
  Future<void> initialize() async {}
  @override
  Future<File> exportDocument({Directory? directory}) async {
    final file = File('${(directory ?? this.directory).path}/logs.txt');
    file.writeAsStringSync(document());
    return file;
  }
}

class _Delivery extends FileExport {
  String? document;
  @override
  Future<void> deliver(
    File file, {
    required String suggestedName,
    required String mimeType,
    required String extension,
    Rect? sharePositionOrigin,
  }) async {
    document = file.readAsStringSync();
    expect(suggestedName, 'ykt-helper-logs.txt');
    expect(mimeType, 'text/plain');
    expect(extension, 'txt');
  }
}

void main() {
  testWidgets('每条日志点击可查看复制详情，导出保留相同错误原因和上下文', (tester) async {
    final directory = Directory.systemTemp.createTempSync('ykt-logs-ui-');
    final logs = _Logs(directory);
    final controller = AppController(
      logs: logs,
      startTimers: false,
      connectSockets: false,
    );
    final delivery = _Delivery();
    await logs.initialize();
    logs.add(
      AppLogEvent.automatic,
      success: false,
      detail: '解析模型回答未匹配选择项',
      error: const ApiFailure('模型回答没有有效选项'),
      context: {'phase': 'parse', 'problemId': 'q1'},
      elapsed: const Duration(milliseconds: 240),
    );
    final expected = logs.entries.single.detailText;
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LogsPage(controller: controller, fileExport: delivery),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log-entry-0')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(find.byKey(const ValueKey('log-detail')))
          .data,
      expected,
    );
    expect(expected, contains('模型回答没有有效选项'));
    expect(expected, contains('phase：parse'));
    await tester.tap(find.widgetWithText(TextButton, '复制'));
    await tester.pumpAndSettle();
    expect(clipboard, expected);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出日志文档'));
    await tester.pumpAndSettle();
    expect(delivery.document, contains(expected));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await logs.flush();
    controller.dispose();
    directory.deleteSync(recursive: true);
  });
}
