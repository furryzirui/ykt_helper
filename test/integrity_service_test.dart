import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/app_info.dart';
import 'package:ykt_helper/services/integrity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android accepts exactly the official single signer', () async {
    const channel = MethodChannel('test/ykt_helper/integrity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'certificateSha256': [
              IntegrityService.officialAndroidCertificateSha256,
            ],
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final result = await IntegrityService(
      platform: 'android',
      channel: channel,
    ).check();
    expect(result.verified, isTrue);
  });

  test('Android rejects a missing or rotating signer', () async {
    const channel = MethodChannel('test/ykt_helper/integrity-multiple');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'certificateSha256': [
              IntegrityService.officialAndroidCertificateSha256,
              '0' * 64,
            ],
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final result = await IntegrityService(
      platform: 'android',
      channel: channel,
    ).check();
    expect(result.verified, isFalse);
    expect(result.detail, '无法验证为官方发布版本');
  });

  test('desktop manifest with invalid signature never passes', () async {
    final directory = await Directory.systemTemp.createTemp('ykt-integrity-');
    addTearDown(() => directory.delete(recursive: true));
    final payload = jsonEncode({
      'schema': 1,
      'app': 'ykt_helper',
      'platform': 'windows',
      'version': AppInfo.version,
      'build': AppInfo.buildNumber,
      'files': [
        {'path': 'ykt_helper.exe', 'algorithm': 'sha256', 'sha256': '0' * 64},
      ],
    });
    await File('${directory.path}/integrity.json').writeAsString(
      jsonEncode({
        'payload': base64Encode(utf8.encode(payload)),
        'signature': base64Encode(List.filled(64, 0)),
      }),
    );
    final result = await IntegrityService(
      platform: 'windows',
      rootPath: directory.path,
      publicKey: List.filled(32, 0),
    ).check();
    expect(result.verified, isFalse);
    expect(result.detail, '无法验证为官方发布版本');
  });

  test(
    'desktop signed manifest verifies files and detects tampering',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ykt-integrity-valid-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final content = utf8.encode('stable application payload');
      await File('${directory.path}/ykt_helper.exe').writeAsBytes(content);
      final digest = (await Sha256().hash(
        content,
      )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final payload = utf8.encode(
        jsonEncode({
          'schema': 1,
          'app': 'ykt_helper',
          'platform': 'windows',
          'version': AppInfo.version,
          'build': AppInfo.buildNumber,
          'files': [
            {'path': 'ykt_helper.exe', 'algorithm': 'sha256', 'sha256': digest},
          ],
        }),
      );
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final signature = await algorithm.sign(payload, keyPair: keyPair);
      final publicKey = await keyPair.extractPublicKey();
      await File('${directory.path}/integrity.json').writeAsString(
        jsonEncode({
          'payload': base64Encode(payload),
          'signature': base64Encode(signature.bytes),
        }),
      );
      final service = IntegrityService(
        platform: 'windows',
        rootPath: directory.path,
        publicKey: publicKey.bytes,
      );
      expect((await service.check()).verified, isTrue);
      await File('${directory.path}/ykt_helper.exe').writeAsString('tampered');
      final result = await service.check();
      expect(result.verified, isFalse);
      expect(result.detail, '程序文件完整性校验未通过');
    },
  );

  test('Mach-O digest ignores normal signing metadata changes', () async {
    final service = IntegrityService();
    final before = _machOFixture();
    final after = Uint8List.fromList(before);
    final data = ByteData.sublistView(after);
    data.setUint64(216, 600, Endian.little);
    data.setUint64(232, 600, Endian.little);
    data.setUint32(264, 600, Endian.little);
    data.setUint32(268, 24, Endian.little);
    after.fillRange(520, after.length, 0x77);
    expect(
      await service.machoDigestForTesting(after),
      await service.machoDigestForTesting(before),
    );
  });

  test('Mach-O digest changes when a code section changes', () async {
    final service = IntegrityService();
    final before = _machOFixture();
    final after = Uint8List.fromList(before)..[512] = 0x11;
    expect(
      await service.machoDigestForTesting(after),
      isNot(await service.machoDigestForTesting(before)),
    );
  });
}

Uint8List _machOFixture() {
  final bytes = Uint8List(624);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xfeedfacf, Endian.little);
  data.setUint32(4, 0x0100000c, Endian.little);
  data.setUint32(12, 2, Endian.little);
  data.setUint32(16, 3, Endian.little);
  data.setUint32(20, 240, Endian.little);
  data.setUint32(32, 0x19, Endian.little);
  data.setUint32(36, 152, Endian.little);
  bytes.setRange(40, 46, ascii.encode('__TEXT'));
  data.setUint32(96, 1, Endian.little);
  bytes.setRange(104, 110, ascii.encode('__text'));
  bytes.setRange(120, 126, ascii.encode('__TEXT'));
  data.setUint64(144, 8, Endian.little);
  data.setUint32(152, 512, Endian.little);
  data.setUint32(168, 0x80000400, Endian.little);
  bytes.setRange(512, 520, [1, 2, 3, 4, 5, 6, 7, 8]);
  data.setUint32(184, 0x19, Endian.little);
  data.setUint32(188, 72, Endian.little);
  bytes.setRange(192, 202, ascii.encode('__LINKEDIT'));
  data.setUint64(216, 104, Endian.little);
  data.setUint64(224, 520, Endian.little);
  data.setUint64(232, 104, Endian.little);
  data.setUint32(256, 0x1d, Endian.little);
  data.setUint32(260, 16, Endian.little);
  data.setUint32(264, 520, Endian.little);
  data.setUint32(268, 104, Endian.little);
  bytes.fillRange(520, bytes.length, 0x33);
  return bytes;
}
