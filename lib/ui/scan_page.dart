import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/app_permissions.dart';
import 'permissions_page.dart';

Future<String?> showQrScanner(BuildContext context) async {
  if ((Platform.isAndroid || Platform.isIOS) &&
      !await ensureAppPermission(context, AppPermission.camera)) {
    return null;
  }
  if (!context.mounted) return null;
  return Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _url = TextEditingController();
  bool _returned = false;
  bool get _cameraSupported => Platform.isAndroid || Platform.isIOS;

  void _finish(String value) {
    if (_returned || value.trim().isEmpty) return;
    _returned = true;
    Navigator.of(context).pop(value.trim());
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫码进入课堂')),
    body: Column(
      children: [
        if (_cameraSupported)
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  final value = barcode.rawValue;
                  if (value != null && value.isNotEmpty) {
                    _finish(value);
                    break;
                  }
                }
              },
              errorBuilder: (context, error) =>
                  const Center(child: Text('无法使用相机，请检查相机权限或输入二维码链接')),
            ),
          )
        else
          const Expanded(child: Center(child: Text('输入课堂二维码链接'))),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    decoration: const InputDecoration(labelText: '二维码链接'),
                    keyboardType: TextInputType.url,
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
