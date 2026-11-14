import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_permissions.dart';
import 'permissions_page.dart';

bool get _cameraSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<String?> showQrScanner(BuildContext context) async {
  if (_cameraSupported &&
      !await ensureAppPermission(context, AppPermission.camera)) {
    return null;
  }
  if (!context.mounted) return null;
  return Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
}

class ScanPage extends StatefulWidget {
  final AppPermissions permissions;
  const ScanPage({super.key, this.permissions = const AppPermissions()});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  final _url = TextEditingController();
  late final _camera = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    cameraResolution: const Size(1280, 720),
    initialZoom: 0,
  );
  Future<void> _operations = Future.value();
  bool _returned = false, _closing = false, _resumed = true;
  bool _permissionDenied = false, _starting = true, _changingCamera = false;
  String? _error;
  int _revision = 0;
  double _zoom = 0, _gestureZoom = 0;
  double? _pendingZoom;
  bool _updatingZoom = false;
  CameraFacing _facing = CameraFacing.back;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_cameraSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateCamera());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _updateCamera();
  }

  bool get _active => mounted && !_closing && !_returned && _resumed;

  Future<void> _updateCamera({bool switchCamera = false}) {
    if (!_cameraSupported || _closing) return Future.value();
    final revision = ++_revision;
    _operations = _operations.catchError((Object _) {}).then((_) async {
      if (_closing || revision != _revision) return;
      if (!_active) {
        try {
          await _camera.stop();
        } catch (_) {
          // The route may be leaving while the native camera is disconnecting.
        }
        return;
      }
      setState(() {
        _starting = true;
        _error = null;
      });
      try {
        // MobileScanner.start can itself request permission. Read the status
        // first so lifecycle resumes never bypass the explained permission flow.
        final states = await widget.permissions.check();
        final permission = states
            .singleWhere((state) => state.permission == AppPermission.camera)
            .status;
        if (!_active || revision != _revision) return;
        if (permission != PermissionStatus.granted) {
          await _camera.stop();
          if (mounted) {
            setState(() {
              _permissionDenied = true;
              _error = '请允许相机权限后重试';
            });
          }
          return;
        }
        _permissionDenied = false;
        if (switchCamera) {
          await _camera.stop();
          _facing = _facing == CameraFacing.back
              ? CameraFacing.front
              : CameraFacing.back;
        }
        if (!_active || revision != _revision) return;
        await _camera.start(cameraDirection: _facing);
        if (!_active || revision != _revision) {
          await _camera.stop();
          return;
        }
        if (_camera.value.error != null) {
          throw _camera.value.error!;
        }
        _zoom = 0;
        await _camera.setZoomScale(0);
      } catch (_) {
        if (_active && revision == _revision) {
          setState(() => _error = '无法使用相机，可重试或输入二维码链接');
        }
      } finally {
        if (mounted && !_closing && revision == _revision) {
          setState(() {
            _starting = false;
            _changingCamera = false;
          });
        }
      }
    });
    return _operations;
  }

  Future<void> _retry() async {
    if (_starting) return;
    if (_permissionDenied &&
        !await ensureAppPermission(
          context,
          AppPermission.camera,
          permissions: widget.permissions,
        )) {
      return;
    }
    if (mounted) await _updateCamera();
  }

  Future<void> _setZoom(double value) async {
    if (!_active || !_camera.value.isRunning || _changingCamera) return;
    final next = value.clamp(0.0, 1.0);
    setState(() => _zoom = next);
    _pendingZoom = next;
    if (_updatingZoom) return;
    _updatingZoom = true;
    try {
      while (_pendingZoom != null && _active && _camera.value.isRunning) {
        final requested = _pendingZoom!;
        _pendingZoom = null;
        await _camera.setZoomScale(requested);
      }
    } catch (_) {
      if (mounted && _active) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前相机无法调整缩放')));
      }
    } finally {
      _updatingZoom = false;
      _pendingZoom = null;
    }
  }

  void _finish(String value) {
    if (_returned || value.trim().isEmpty) return;
    _returned = true;
    _updateCamera();
    Navigator.of(context).pop(value.trim());
  }

  @override
  void dispose() {
    _closing = true;
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    _url.dispose();
    if (_cameraSupported) {
      unawaited(
        _operations
            .catchError((Object _) {})
            .then((_) => _camera.dispose())
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  Widget _cameraControls(MobileScannerState state) {
    final enabled = state.isRunning && !_starting && !_changingCamera;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Material(
        color: Colors.black.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(30),
        child: Row(
          children: [
            IconButton(
              tooltip: '缩小',
              color: Colors.white,
              disabledColor: Colors.white38,
              onPressed: enabled ? () => _setZoom(_zoom - .1) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            Expanded(
              child: Slider(
                key: const ValueKey('scanner-zoom'),
                value: _zoom,
                activeColor: Colors.white,
                inactiveColor: Colors.white38,
                onChanged: enabled ? _setZoom : null,
                semanticFormatterCallback: (value) =>
                    '相机缩放 ${(value * 100).round()}%',
              ),
            ),
            IconButton(
              tooltip: '放大',
              color: Colors.white,
              disabledColor: Colors.white38,
              onPressed: enabled ? () => _setZoom(_zoom + .1) : null,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview() => ValueListenableBuilder<MobileScannerState>(
    valueListenable: _camera,
    builder: (context, state, _) => LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final hasRoom = size.height >= 130 && size.width >= 140;
        final side = math.min(
          340.0,
          math.min(
            math.max(0.0, size.width - 40),
            math.max(0.0, size.height - 100),
          ),
        );
        final window = Rect.fromCenter(
          center: Offset(size.width / 2, math.max(0.0, size.height - 76) / 2),
          width: side,
          height: side,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('scanner-pinch'),
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) => _gestureZoom = _zoom,
              onScaleUpdate: (details) {
                if (details.pointerCount >= 2) {
                  _setZoom(_gestureZoom + (details.scale - 1) * .5);
                }
              },
              child: MobileScanner(
                controller: _camera,
                useAppLifecycleState: false,
                scanWindow: hasRoom ? window : null,
                tapToFocus: true,
                onDetect: (capture) {
                  if (!_active) return;
                  for (final barcode in capture.barcodes) {
                    final value = barcode.rawValue;
                    if (value != null && value.isNotEmpty) {
                      _finish(value);
                      break;
                    }
                  }
                },
                placeholderBuilder: (_) =>
                    const ColoredBox(color: Colors.black),
                errorBuilder: (_, _) => const ColoredBox(color: Colors.black),
              ),
            ),
            if (hasRoom && _error == null)
              IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('scanner-frame'),
                  painter: _ScanFramePainter(
                    window,
                    Theme.of(context).colorScheme.primaryContainer,
                  ),
                ),
              ),
            if (_starting)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            if (_error != null && hasRoom)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _starting ? null : _retry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(_permissionDenied ? '相机权限' : '重试'),
                      ),
                    ],
                  ),
                ),
              ),
            if (hasRoom && _error == null) _cameraControls(state),
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('扫码进入课堂'),
      actions: [
        if (_cameraSupported)
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _camera,
            builder: (context, state, _) => Row(
              children: [
                if (state.torchState != TorchState.unavailable)
                  IconButton(
                    tooltip: '闪光灯',
                    onPressed: !state.isRunning || _starting
                        ? null
                        : () async {
                            try {
                              await _camera.toggleTorch();
                            } catch (_) {
                              // Hardware capability can change after switching cameras.
                            }
                          },
                    icon: Icon(
                      state.torchState == TorchState.on
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                    ),
                  ),
                if ((state.availableCameras ?? 0) > 1)
                  IconButton(
                    tooltip: '切换相机',
                    onPressed: !state.isRunning || _starting || _changingCamera
                        ? null
                        : () {
                            setState(() => _changingCamera = true);
                            _updateCamera(switchCamera: true);
                          },
                    icon: const Icon(Icons.cameraswitch_outlined),
                  ),
              ],
            ),
          ),
      ],
    ),
    body: Column(
      children: [
        Expanded(
          child: _cameraSupported
              ? _preview()
              : const Center(child: Text('输入课堂二维码链接')),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    decoration: const InputDecoration(labelText: '二维码链接'),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _finish,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => _finish(_url.text),
                  child: const Text('进入'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ScanFramePainter extends CustomPainter {
  final Rect window;
  final Color color;
  const _ScanFramePainter(this.window, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cutout = RRect.fromRectAndRadius(window, const Radius.circular(16));
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(cutout),
      ),
      Paint()..color = Colors.black.withValues(alpha: .55),
    );
    canvas.drawRRect(
      cutout,
      Paint()
        ..color = Colors.white54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final corner in [
      window.topLeft,
      window.topRight,
      window.bottomRight,
      window.bottomLeft,
    ]) {
      final dx = corner.dx == window.left ? 1.0 : -1.0;
      final dy = corner.dy == window.top ? 1.0 : -1.0;
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx, corner.dy + dy * 28)
          ..lineTo(corner.dx, corner.dy + dy * 8)
          ..quadraticBezierTo(
            corner.dx,
            corner.dy,
            corner.dx + dx * 8,
            corner.dy,
          )
          ..lineTo(corner.dx + dx * 28, corner.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ScanFramePainter oldDelegate) =>
      oldDelegate.window != window || oldDelegate.color != color;
}
