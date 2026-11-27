import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/app_info.dart';
import 'package:ykt_helper/ui/about_page.dart';

void main() {
  testWidgets('关于同时显示版本和构建号', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    expect(
      find.text('版本 ${AppInfo.version}（build ${AppInfo.buildNumber}）'),
      findsOneWidget,
    );
  });
}
