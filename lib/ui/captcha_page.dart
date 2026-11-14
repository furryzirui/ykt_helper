import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'captcha_protocol.dart';
import 'windows_captcha_page.dart';

export 'captcha_protocol.dart' show CaptchaResult;

Future<CaptchaResult?> showTencentCaptcha(BuildContext context) =>
    Navigator.of(context).push<CaptchaResult>(
      MaterialPageRoute(
        builder: (_) => Platform.isWindows
            ? const WindowsCaptchaPage()
            : const CaptchaPage(),
      ),
    );

class CaptchaPage extends StatefulWidget {
  const CaptchaPage({super.key});
  @override
  State<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends State<CaptchaPage> {
  WebViewController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'CaptchaBridge',
        onMessageReceived: (message) {
          final result = parseCaptchaMessage(message.message);
          if (result != null && mounted) {
            Navigator.of(context).pop(result);
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            return isAllowedCaptchaUrl(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => _error = '验证码加载失败，请重试');
            }
          },
        ),
      )
      ..loadHtmlString(
        captchaHtml(),
        baseUrl: 'https://turing.captcha.qcloud.com/',
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('安全验证')),
    body: _controller == null
        ? const Center(child: Text('当前平台暂不支持安全验证，请使用二维码登录'))
        : Column(
            children: [
              if (_error != null)
                MaterialBanner(
                  content: Text(_error!),
                  actions: [
                    TextButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _controller!.loadHtmlString(
                          captchaHtml(),
                          baseUrl: 'https://turing.captcha.qcloud.com/',
                        );
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              Expanded(child: WebViewWidget(controller: _controller!)),
            ],
          ),
  );
}
