import 'dart:convert';

class CaptchaResult {
  final String ticket, rand;
  const CaptchaResult(this.ticket, this.rand);
}

bool isAllowedCaptchaUrl(String url) {
  if (url == 'about:blank') return true;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return [
    'captcha.qq.com',
    'captcha.qcloud.com',
    'captcha.gtimg.com',
    'tencentcloudapi.com',
  ].any((domain) => host == domain || host.endsWith('.$domain'));
}

CaptchaResult? parseCaptchaMessage(Object? raw, {String? nonce}) {
  try {
    final value = raw is String ? jsonDecode(raw) : raw;
    if (value is! Map) return null;
    if (nonce != null &&
        (value['kind'] != 'captcha-result' || value['nonce'] != nonce)) {
      return null;
    }
    final ticket = value['ticket'], rand = value['rand'];
    if (ticket is! String ||
        rand is! String ||
        ticket.isEmpty ||
        rand.isEmpty ||
        ticket.length > 8192 ||
        rand.length > 1024) {
      return null;
    }
    return CaptchaResult(ticket, rand);
  } catch (_) {
    return null;
  }
}

String captchaHtml({String? windowsNonce}) {
  final post = windowsNonce == null
      ? 'CaptchaBridge.postMessage(JSON.stringify({ticket:r.ticket,rand:r.randstr}));'
      : 'window.chrome.webview.postMessage({kind:"captcha-result",nonce:${jsonEncode(windowsNonce)},ticket:r.ticket,rand:r.randstr});';
  return '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src https: data: blob: 'unsafe-inline'; script-src 'unsafe-inline' 'unsafe-eval' https://captcha.qcloud.com https://*.captcha.qcloud.com https://captcha.gtimg.com https://*.captcha.gtimg.com https://captcha.qq.com https://*.captcha.qq.com; connect-src https:; form-action 'none'; base-uri 'none';">
<style>body{font:16px sans-serif;text-align:center;padding:40px 12px}button{padding:12px 30px;font:inherit}</style>
<script src="https://turing.captcha.qcloud.com/TCaptcha.js"></script>
</head><body><button onclick="verify()">开始验证</button>
<script>function verify(){var c=new TencentCaptcha('2091064951',function(r){
if(r.ret===0){$post}
});c.show();}window.onload=verify;</script></body></html>''';
}
