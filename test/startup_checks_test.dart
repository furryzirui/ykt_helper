import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ykt_helper/services/startup_checks.dart';
import 'package:ykt_helper/services/integrity_service.dart';

void main() {
  testWidgets('background launch defers dialogs until the first foreground', (
    tester,
  ) async {
    var checks = 0;
    Future<IntegrityResult> check() async {
      checks++;
      return const IntegrityResult(verified: true);
    }

    Widget page(bool foreground) => MaterialApp(
      home: StartupChecks(
        enabled: foreground,
        integrityCheck: check,
        updateCheck: () async => null,
        child: const Scaffold(body: Text('ready')),
      ),
    );
    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(checks, 0);
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(checks, 1);
    await tester.pumpWidget(page(false));
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  test('semantic version comparison handles 1.0.10 correctly', () {
    expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    expect(compareVersions('v1.0.1+6', '1.0.1'), 0);
    expect(parseVersion('bad'), isNull);
  });

  test(
    'update service ignores old, draft, prerelease and malformed releases',
    () async {
      Future<UpdateInfo?> check(Map<String, dynamic> data) => UpdateService(
        currentVersion: '1.0.1',
        fetcher: () async => data,
      ).check();
      final current = await check({'tag_name': 'v1.0.10'});
      expect(current, isNotNull);
      expect(current!.url.toString(), githubReleasesUrl);
      expect(await check({'tag_name': 'v1.0.0'}), isNull);
      expect(await check({'tag_name': 'v1.0.2', 'draft': true}), isNull);
      expect(await check({'tag_name': 'v1.0.2', 'prerelease': true}), isNull);
      expect(await check({'tag_name': 'v1.0.2-beta'}), isNull);
      expect(await check({'tag_name': 'latest'}), isNull);
    },
  );

  testWidgets('startup coordinator runs injected checks once', (tester) async {
    var integrityCalls = 0;
    var fetchCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StartupChecks(
          integrityCheck: () async {
            integrityCalls++;
            return const IntegrityResult(verified: true);
          },
          updateCheck: () {
            fetchCalls++;
            return UpdateService(
              fetcher: () async => {'tag_name': 'v1.0.0'},
            ).check();
          },
          child: const Scaffold(body: Text('ready')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(integrityCalls, 1);
    expect(fetchCalls, 1);
  });

  testWidgets('integrity warning can continue to the update notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StartupChecks(
          integrityCheck: () async =>
              const IntegrityResult(verified: false, detail: '完整性检查失败'),
          updateCheck: () async =>
              UpdateInfo(version: '1.0.2', url: Uri.parse(githubReleasesUrl)),
          child: const Scaffold(body: Text('ready')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('风险提示'), findsOneWidget);
    await tester.tap(find.text('继续使用'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 1.0.2'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets(
    'update checker errors are silent and a rebuild does not repeat checks',
    (tester) async {
      var integrityCalls = 0;
      var updateCalls = 0;
      final child = StartupChecks(
        integrityCheck: () async {
          integrityCalls++;
          return const IntegrityResult(verified: true);
        },
        updateCheck: () async {
          updateCalls++;
          throw StateError('offline');
        },
        child: const Scaffold(body: Text('ready')),
      );
      await tester.pumpWidget(MaterialApp(home: child));
      await tester.pumpAndSettle();
      await tester.pumpWidget(MaterialApp(home: child));
      await tester.pumpAndSettle();
      expect(find.text('ready'), findsOneWidget);
      expect(integrityCalls, 1);
      expect(updateCalls, 1);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('late integrity result after leaving the page shows no dialog', (
    tester,
  ) async {
    final completer = Completer<IntegrityResult>();
    await tester.pumpWidget(
      MaterialApp(
        home: StartupChecks(
          integrityCheck: () => completer.future,
          child: const Scaffold(body: Text('ready')),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Text('other')));
    completer.complete(const IntegrityResult(verified: false));
    await tester.pumpAndSettle();
    expect(find.text('风险提示'), findsNothing);
    expect(find.text('other'), findsOneWidget);
  });
}
