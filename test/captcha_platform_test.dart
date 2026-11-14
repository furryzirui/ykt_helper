import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/ui/captcha_protocol.dart';

void main() {
  test('captcha navigation accepts HTTPS official domains only', () {
    for (final url in [
      'about:blank',
      'https://turing.captcha.qcloud.com/',
      'https://captcha.qq.com/path',
      'https://sub.captcha.gtimg.com/path',
    ]) {
      expect(isAllowedCaptchaUrl(url), isTrue, reason: url);
    }
    for (final url in [
      'http://captcha.qq.com/',
      'https://captcha.qq.com.evil.invalid/',
      'https://evilcaptcha.qq.com/',
      'https://user@captcha.qq.com/',
      'https://captcha.qq.com:444/',
      'file:///private',
      'javascript:alert(1)',
    ]) {
      expect(isAllowedCaptchaUrl(url), isFalse, reason: url);
    }
  });

  test('windows captcha bridge validates type and per-page nonce', () {
    const payload = {
      'kind': 'captcha-result',
      'nonce': 'current-page',
      'ticket': 'ticket',
      'rand': 'random',
    };
    expect(
      parseCaptchaMessage(payload, nonce: 'current-page')!.ticket,
      'ticket',
    );
    expect(parseCaptchaMessage(payload, nonce: 'old-page'), isNull);
    expect(
      parseCaptchaMessage({
        'ticket': 'ticket',
        'rand': 'random',
      }, nonce: 'current-page'),
      isNull,
    );
    expect(parseCaptchaMessage({'ticket': 42, 'rand': 'random'}), isNull);
    expect(parseCaptchaMessage('{bad-json'), isNull);
    expect(
      parseCaptchaMessage('{"ticket":"ticket","rand":"random"}')!.rand,
      'random',
    );
    expect(
      captchaHtml(windowsNonce: 'current-page'),
      contains('window.chrome.webview.postMessage'),
    );
    expect(captchaHtml(), contains('CaptchaBridge.postMessage'));
  });
}
