import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class CaptchaResult {
  final String ticket, rand;
  const CaptchaResult(this.ticket, this.rand);
}

Future<CaptchaResult?> showTencentCaptcha(BuildContext context) => Navigator.of(
  context,
).push<CaptchaResult>(MaterialPageRoute(builder: (_) => const CaptchaPage()));

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
          try {
            final value = jsonDecode(message.message) as Map<String, dynamic>;
            final ticket = value['ticket']?.toString() ?? '';
            final rand = value['rand']?.toString() ?? '';
            if (ticket.isNotEmpty && rand.isNotEmpty && mounted) {
              Navigator.of(context).pop(CaptchaResult(ticket, rand));
            }
          } catch (_) {
            if (mounted) setState(() => _error = '验证码响应无效，请重试');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            final host = uri?.host ?? '';
            return request.url == 'about:blank' ||
                    (uri?.scheme == 'https' &&
                        (host == 'captcha.qq.com' ||
                            host.endsWith('.captcha.qq.com') ||
                            host == 'captcha.qcloud.com' ||
                            host.endsWith('.captcha.qcloud.com') ||
                            host == 'captcha.gtimg.com' ||
                            host.endsWith('.captcha.gtimg.com') ||
                            host.endsWith('.tencentcloudapi.com')))
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
      ..loadHtmlString(_html, baseUrl: 'https://turing.captcha.qcloud.com/');
  }

  static const _html = '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src https: data: blob: 'unsafe-inline'; script-src 'unsafe-inline' 'unsafe-eval' https://captcha.qcloud.com https://*.captcha.qcloud.com https://captcha.gtimg.com https://*.captcha.gtimg.com https://captcha.qq.com https://*.captcha.qq.com; connect-src https:;">
<style>body{font:16px sans-serif;text-align:center;padding:40px 12px}button{padding:12px 30px;font:inherit}</style>
<script src="https://turing.captcha.qcloud.com/TCaptcha.js"></script>
</head><body><button onclick="verify()">开始验证</button>
<script>function verify(){var c=new TencentCaptcha('2091064951',function(r){
if(r.ret===0){CaptchaBridge.postMessage(JSON.stringify({ticket:r.ticket,rand:r.randstr}));}
});c.show();}window.onload=verify;</script></body></html>''';

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
                          _html,
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
