import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import '../services/app_logs.dart';
import 'captcha_page.dart';

class LoginPage extends StatefulWidget {
  final AppController controller;
  const LoginPage({super.key, required this.controller});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController(), _secret = TextEditingController();
  Json? _qr;
  String? _error;
  bool _working = false, _expired = false, _authorized = false;
  bool get _sms => _mode == 1;
  int _generation = 0;
  DateTime? _expiresAt;
  Timer? _ticker;
  int _mode = 0;

  @override
  void initState() {
    super.initState();
    _refreshQr();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
        if (!_expired && mounted) {
          _generation++;
          widget.controller.api.cancelQr();
          setState(() => _expired = true);
        }
      } else if (mounted && _qr != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.api.cancelQr();
    _ticker?.cancel();
    _account.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _refreshQr() async {
    final generation = ++_generation;
    setState(() {
      _working = true;
      _error = null;
      _expired = false;
      _authorized = false;
      _qr = null;
    });
    try {
      final data = await widget.controller.api.createQr();
      if (!mounted || generation != _generation) return;
      final expires = integer(data['expireSeconds'] ?? data['expiresIn']);
      setState(() {
        _qr = data;
        _working = false;
        _expiresAt = expires > 0
            ? DateTime.now().add(Duration(seconds: expires))
            : null;
      });
      while (mounted && generation == _generation && !_expired) {
        final authorized = await widget.controller.api.pollQr(
          str(data['token']),
        );
        if (!mounted || generation != _generation) return;
        if (authorized) {
          setState(() {
            _authorized = true;
            _qr = null;
            _expiresAt = null;
            _working = true;
          });
          await widget.controller.loginCompleted();
          if (mounted) Navigator.of(context).pop();
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (error) {
      widget.controller.logs.add(
        AppLogEvent.login,
        success: false,
        code: error is ApiFailure ? error.code : null,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _working = false;
        _qr = null;
        _expired = error is ApiFailure && error.code == 50001;
        _error = _expired ? '二维码已过期，请刷新' : error.toString();
      });
    }
  }

  Future<void> _retryProfile() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.loginCompleted();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      widget.controller.logs.add(
        AppLogEvent.login,
        success: false,
        code: error is ApiFailure ? error.code : null,
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _sendSms() async {
    if (_account.text.trim().isEmpty) {
      setState(() => _error = '请输入手机号');
      return;
    }
    final captcha = await showTencentCaptcha(context);
    if (captcha == null || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.api.sendSms(
        _account.text.trim(),
        captcha.ticket,
        captcha.rand,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('验证码已发送')));
      }
    } catch (error) {
      widget.controller.logs.add(
        AppLogEvent.login,
        success: false,
        code: error is ApiFailure ? error.code : null,
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _login() async {
    if (_account.text.trim().isEmpty || _secret.text.isEmpty) {
      setState(() => _error = _sms ? '请输入手机号和短信验证码' : '请输入账号和密码');
      return;
    }
    final captcha = await showTencentCaptcha(context);
    if (captcha == null || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.api.login(
        account: _account.text.trim(),
        secret: _secret.text,
        sms: _sms,
        ticket: captcha.ticket,
        rand: captcha.rand,
      );
      await widget.controller.loginCompleted();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      widget.controller.logs.add(
        AppLogEvent.login,
        success: false,
        code: error is ApiFailure ? error.code : null,
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('登录雨课堂')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('二维码')),
                ButtonSegment(value: 1, label: Text('验证码')),
                ButtonSegment(value: 2, label: Text('账号密码')),
              ],
              selected: {_mode},
              onSelectionChanged: _working && _mode != 0
                  ? null
                  : (selection) {
                      final mode = selection.first;
                      setState(() {
                        _mode = mode;
                        _secret.clear();
                        _qr = null;
                        _authorized = false;
                        _expiresAt = null;
                        _error = null;
                        _working = false;
                      });
                      if (mode == 0) {
                        _refreshQr();
                      } else {
                        _generation++;
                        widget.controller.api.cancelQr();
                      }
                    },
            ),
            const SizedBox(height: 24),
            if (_mode == 0) ...[
              if (_working) const Center(child: CircularProgressIndicator()),
              if (_qr != null && !_expired) ...[
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: str(_qr!['qrImage']).isNotEmpty
                        ? Image.network(
                            str(_qr!['qrImage']),
                            width: 240,
                            height: 240,
                            errorBuilder: (context, error, stack) =>
                                str(_qr!['qrContent']).isNotEmpty
                                ? QrImageView(
                                    data: str(_qr!['qrContent']),
                                    size: 240,
                                  )
                                : const SizedBox(
                                    width: 240,
                                    height: 240,
                                    child: Center(child: Text('二维码加载失败')),
                                  ),
                          )
                        : QrImageView(data: str(_qr!['qrContent']), size: 240),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('扫描二维码并确认登录', textAlign: TextAlign.center),
                if (_expiresAt != null)
                  Text(
                    '剩余 ${_expiresAt!.difference(DateTime.now()).inSeconds.clamp(0, 999)} 秒',
                    textAlign: TextAlign.center,
                  ),
              ],
              if (_expired) const Center(child: Text('二维码已过期')),
              if (_authorized) ...[
                const Text('已授权，正在获取账号信息', textAlign: TextAlign.center),
                if (!_working)
                  FilledButton(
                    onPressed: _retryProfile,
                    child: const Text('重试获取账号信息'),
                  ),
              ],
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _working ? null : _refreshQr,
                child: const Text('刷新二维码'),
              ),
            ] else ...[
              TextField(
                controller: _account,
                keyboardType: _sms
                    ? TextInputType.phone
                    : TextInputType.emailAddress,
                decoration: InputDecoration(labelText: _sms ? '手机号' : '手机号或邮箱'),
                autofillHints: const [AutofillHints.username],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _secret,
                obscureText: !_sms,
                keyboardType: _sms
                    ? TextInputType.number
                    : TextInputType.visiblePassword,
                autofillHints: _sms
                    ? const [AutofillHints.oneTimeCode]
                    : const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: _sms ? '短信验证码' : '密码',
                  suffixIcon: _sms
                      ? TextButton(
                          onPressed: _working ? null : _sendSms,
                          child: const Text('发送验证码'),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _working ? null : _login,
                child: Text(_working ? '登录中…' : '登录'),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
