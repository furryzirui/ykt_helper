import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ykt_helper/services/app_permissions.dart';
import 'package:ykt_helper/ui/scan_page.dart';

class _Permissions extends AppPermissions {
  PermissionStatus camera = PermissionStatus.granted;
  int requests = 0;
  @override
  Future<List<AppPermissionState>> check() async => [
    for (final permission in AppPermission.values)
      AppPermissionState(
        permission: permission,
        status: permission == AppPermission.camera
            ? camera
            : PermissionStatus.notRequired,
      ),
  ];

  @override
  Future<bool> request(AppPermission permission) async {
    requests++;
    camera = PermissionStatus.granted;
    return true;
  }
}

class _Scanner extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  final torches = StreamController<TorchState>.broadcast();
  final zooms = StreamController<double>.broadcast();
  final starts = <StartOptions>[];
  final zoomValues = <double>[];
  final windows = <Rect?>[];
  int stops = 0, disposals = 0, torchToggles = 0;
  bool failStart = false, flashAvailable = true;
  int cameras = 2;

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => torches.stream;
  @override
  Stream<double> get zoomScaleStateStream => zooms.stream;
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts.add(options);
    if (failStart) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
      );
    }
    return MobileScannerViewAttributes(
      cameraDirection: options.cameraDirection,
      currentTorchMode: flashAvailable
          ? TorchState.off
          : TorchState.unavailable,
      numberOfCameras: cameras,
      size: const Size(720, 1280),
      initialDeviceOrientation: DeviceOrientation.portraitUp,
    );
  }

  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> setZoomScale(double zoomScale) async {
    zoomValues.add(zoomScale);
    zooms.add(zoomScale);
  }

  @override
  Future<void> setFocusPoint(Offset position) async {}
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> dispose() async => disposals++;
  @override
  Future<void> updateScanWindow(Rect? window) async => windows.add(window);
  @override
  Future<void> toggleTorch() async {
    torchToggles++;
    torches.add(TorchState.on);
  }

  Future<void> close() async {
    await captures.close();
    await torches.close();
    await zooms.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Scanner scanner;
  late _Permissions permissions;
  late MobileScannerPlatform original;

  setUp(() {
    MobileScannerController.resetPlatformSessionOwner();
    original = MobileScannerPlatform.instance;
    scanner = _Scanner();
    permissions = _Permissions();
    MobileScannerPlatform.instance = scanner;
  });
  tearDown(() async {
    MobileScannerPlatform.instance = original;
    MobileScannerController.resetPlatformSessionOwner();
    debugDefaultTargetPlatformOverride = null;
    await scanner.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(360, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: ScanPage(permissions: permissions)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('visible scan frame uses the camera recognition window', (
    tester,
  ) async {
    await mount(tester);
    final widget = tester.widget<MobileScanner>(find.byType(MobileScanner));
    final frame = widget.scanWindow!;
    final preview = tester.getSize(find.byType(MobileScanner));
    expect(frame.width, frame.height);
    expect(frame.width, greaterThan(200));
    expect(frame.left, greaterThanOrEqualTo(0));
    expect(frame.right, lessThanOrEqualTo(preview.width));
    expect(frame.bottom, lessThan(preview.height - 60));
    expect(find.byKey(const ValueKey('scanner-frame')), findsOneWidget);
    expect(scanner.windows.last, isNotNull);
    expect(scanner.starts.single.formats, [BarcodeFormat.qrCode]);
    expect(scanner.starts.single.cameraResolution, const Size(1280, 720));
    expect(permissions.requests, 0);
    await cleanup(tester);
    expect(scanner.disposals, greaterThan(0));
  });

  testWidgets(
    'pinch and slider adjust normalized camera zoom in both directions',
    (tester) async {
      await mount(tester);
      final center = tester.getCenter(
        find.byKey(const ValueKey('scanner-pinch')),
      );
      final first = await tester.startGesture(center - const Offset(40, 0));
      final second = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 2,
      );
      await first.moveTo(center - const Offset(90, 0));
      await second.moveTo(center + const Offset(90, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(scanner.zoomValues.any((value) => value > 0), isTrue);
      final before = scanner.zoomValues.last;
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('scanner-zoom')),
      );
      slider.onChanged!(.2);
      await tester.pumpAndSettle();
      expect(scanner.zoomValues.last, .2);
      expect(before, greaterThan(0));
      final gesture = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('scanner-pinch')),
      );
      gesture.onScaleStart!(ScaleStartDetails());
      gesture.onScaleUpdate!(ScaleUpdateDetails(scale: .1, pointerCount: 2));
      await tester.pumpAndSettle();
      expect(scanner.zoomValues.last, 0);
      expect(
        scanner.zoomValues.every((value) => value >= 0 && value <= 1),
        isTrue,
      );
      await cleanup(tester);
    },
  );

  testWidgets(
    'camera tools follow hardware capabilities and restore after resume',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byTooltip('闪光灯'));
      await tester.pumpAndSettle();
      expect(scanner.torchToggles, 1);
      await tester.tap(find.byTooltip('切换相机'));
      await tester.pumpAndSettle();
      expect(scanner.starts.last.cameraDirection, CameraFacing.front);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(scanner.stops, greaterThan(0));
      final previousStarts = scanner.starts.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(scanner.starts.length, previousStarts + 1);
      expect(scanner.starts.last.cameraDirection, CameraFacing.front);
      await cleanup(tester);
    },
  );

  testWidgets(
    'missing camera permissions require explicit explained confirmation',
    (tester) async {
      permissions.camera = PermissionStatus.denied;
      await mount(tester);
      expect(scanner.starts, isEmpty);
      expect(permissions.requests, 0);
      await tester.tap(find.widgetWithText(FilledButton, '相机权限'));
      await tester.pumpAndSettle();
      expect(find.textContaining('用于扫描课堂二维码'), findsOneWidget);
      expect(scanner.starts, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(permissions.requests, 0);
      await tester.tap(find.widgetWithText(FilledButton, '相机权限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续授权'));
      await tester.pumpAndSettle();
      expect(permissions.requests, 1);
      expect(scanner.starts.length, 1);
      await cleanup(tester);
    },
  );

  testWidgets('camera failure offers retry and unsupported tools are absent', (
    tester,
  ) async {
    scanner.failStart = true;
    scanner.flashAvailable = false;
    scanner.cameras = 1;
    await mount(tester);
    expect(find.text('重试'), findsOneWidget);
    scanner.failStart = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(scanner.starts.length, 2);
    expect(find.byTooltip('闪光灯'), findsNothing);
    expect(find.byTooltip('切换相机'), findsNothing);
    expect(find.byKey(const ValueKey('scanner-frame')), findsOneWidget);
    await cleanup(tester);
  });

  testWidgets(
    'resume after permission revocation does not request it silently',
    (tester) async {
      await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      permissions.camera = PermissionStatus.denied;
      final count = scanner.starts.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(scanner.starts.length, count);
      expect(permissions.requests, 0);
      expect(find.text('请允许相机权限后重试'), findsOneWidget);
      await cleanup(tester);
    },
  );

  for (final size in [const Size(800, 360), const Size(320, 240)]) {
    testWidgets('landscape and short viewport fit $size', (tester) async {
      await mount(tester, size: size);
      expect(tester.takeException(), isNull);
      await tester.showKeyboard(find.byType(TextField));
      tester.view.viewInsets = FakeViewPadding(bottom: size.height / 2 - 20);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await cleanup(tester);
    });
  }

  testWidgets('Windows offers manual entry without creating a camera session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await mount(tester);
    expect(find.text('输入课堂二维码链接'), findsOneWidget);
    expect(find.byType(MobileScanner), findsNothing);
    expect(scanner.starts, isEmpty);
    await cleanup(tester);
  });

  testWidgets('repeated barcode events return once and release the camera', (
    tester,
  ) async {
    var returns = 0;
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => ScanPage(permissions: permissions),
                ),
              );
              returns++;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    const capture = BarcodeCapture(
      barcodes: [Barcode(rawValue: ' https://www.yuketang.cn/abc ')],
    );
    scanner.captures.add(capture);
    scanner.captures.add(capture);
    await tester.pumpAndSettle();
    expect(returns, 1);
    expect(result, 'https://www.yuketang.cn/abc');
    expect(scanner.disposals, greaterThan(0));
    await cleanup(tester);
  });
}
