import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

import 'captcha_protocol.dart';

class WindowsCaptchaPage extends StatefulWidget {
  const WindowsCaptchaPage({super.key});

  @override
  State<WindowsCaptchaPage> createState() => _WindowsCaptchaPageState();
}

class _WindowsCaptchaPageState extends State<WindowsCaptchaPage> {
  static Future<void>? _environment;
  final _controller = WebviewController();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _nonce = base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  late Future<void> _initialization;
  String _url = 'about:blank';
  String? _error;
  bool _ready = false, _returned = false, _runtimeMissing = false;

  static Future<void> _prepareEnvironment() async {
    final support = await getApplicationSupportDirectory();
    await WebviewController.initializeEnvironment(
      userDataPath: '${support.path}/captcha-webview',
    );
  }

  @override
  void initState() {
    super.initState();
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    try {
      if (await WebviewController.getWebViewVersion() == null) {
        if (mounted) {
          setState(() {
            _runtimeMissing = true;
            _error = '需要安装 Microsoft Edge WebView2 Runtime';
          });
        }
        return;
      }
      await (_environment ??= _prepareEnvironment().catchError((Object error) {
        _environment = null;
        throw error;
      }));
      if (!mounted) return;
      await _controller.initialize();
      if (!mounted) return;
      _subscriptions.add(
        _controller.url.listen((url) {
          _url = url;
          if (!isAllowedCaptchaUrl(url)) {
            unawaited(_controller.stop());
            if (mounted) setState(() => _error = '验证码跳转地址无效，请重试');
          }
        }),
      );
      _subscriptions.add(
        _controller.webMessage.listen((message) {
          if (_returned || !mounted || !isAllowedCaptchaUrl(_url)) return;
          final result = parseCaptchaMessage(message, nonce: _nonce);
          if (result == null) return;
          _returned = true;
          Navigator.of(context).pop(result);
        }, onError: (Object _) {}),
      );
      _subscriptions.add(
        _controller.onLoadError.listen((_) {
          if (mounted) setState(() => _error = '验证码加载失败，请重试');
        }),
      );
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.loadStringContent(captchaHtml(windowsNonce: _nonce));
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = '安全验证初始化失败，可重试或使用二维码登录');
    }
  }

  Future<void> _retry() async {
    if (!_ready) {
      if (!_controller.value.isInitialized) {
        setState(() {
          _error = null;
          _runtimeMissing = false;
        });
        _initialization = _initialize();
        return;
      }
      setState(() => _ready = true);
    }
    setState(() => _error = null);
    try {
      await _controller.loadStringContent(captchaHtml(windowsNonce: _nonce));
    } catch (_) {
      if (mounted) setState(() => _error = '验证码加载失败，请重试');
    }
  }

  Future<void> _openRuntime() async {
    try {
      if (!await launchUrl(
        Uri.parse('https://developer.microsoft.com/microsoft-edge/webview2/'),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('Browser unavailable');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开浏览器，请安装 WebView2 Runtime 后重试');
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    // The plugin cannot be disposed while its native initialization is pending.
    unawaited(
      _initialization.then((_) async {
        if (_controller.value.isInitialized) await _controller.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('安全验证')),
    body: Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              if (_runtimeMissing)
                TextButton(onPressed: _openRuntime, child: const Text('安装运行时')),
              TextButton(onPressed: _retry, child: const Text('重试')),
            ],
          ),
        Expanded(
          child: !_ready
              ? _error == null
                    ? const Center(child: CircularProgressIndicator())
                    : const SizedBox()
              : Webview(
                  _controller,
                  permissionRequested: (_, _, _) =>
                      WebviewPermissionDecision.deny,
                ),
        ),
      ],
    ),
  );
}
