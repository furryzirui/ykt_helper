import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import '../domain/app_info.dart';

/// Result of the best-effort local release integrity check.
class IntegrityResult {
  final bool verified;
  final String? detail;
  const IntegrityResult({required this.verified, this.detail});
}

/// Verifies the official Android signing certificate or a signed desktop/iOS
/// file manifest. A failure is deliberately reported as unverified; an absent
/// checker must never silently become a successful verification.
class IntegrityService {
  static const channelName = 'ykt_helper/integrity';
  static const officialAndroidCertificateSha256 =
      'a1a111e5df677fd367379bafe5846fdb4ef7afcc80d16cd9bbec002a0d2cb8c3';
  static const integrityFileName = 'integrity.json';

  // This is replaced only when the release signing public key is rotated.
  // An empty key is intentionally invalid rather than an implicit pass.
  static const officialManifestPublicKeyBase64 =
      'vw8vjofbMl9nlTDI7S2dJ0WL4l/b0ilC+KSdjNd7VWo=';

  final MethodChannel channel;
  final String? platformOverride;
  final String? rootPathOverride;
  final List<int> publicKeyBytes;

  IntegrityService({
    MethodChannel? channel,
    String? platform,
    String? rootPath,
    List<int>? publicKey,
  }) : channel = channel ?? const MethodChannel(channelName),
       platformOverride = platform,
       rootPathOverride = rootPath,
       publicKeyBytes =
           publicKey ?? base64.decode(officialManifestPublicKeyBase64);

  String get _platform {
    if (platformOverride != null) return platformOverride!;
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    return 'unsupported';
  }

  Future<IntegrityResult> check() async {
    try {
      switch (_platform) {
        case 'android':
          return await _checkAndroid();
        case 'windows':
        case 'ios':
          return await _checkManifest(_platform);
        default:
          return const IntegrityResult(
            verified: false,
            detail: '当前平台无法验证官方发布版本',
          );
      }
    } catch (_) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
  }

  Future<IntegrityResult> _checkAndroid() async {
    final raw = await channel.invokeMethod<dynamic>('identity');
    final values = raw is Map ? raw['certificateSha256'] : null;
    if (values is! List || values.length != 1 || values.first is! String) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    final certificate = (values.first as String).toLowerCase();
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(certificate) &&
        certificate == officialAndroidCertificateSha256) {
      return const IntegrityResult(verified: true);
    }
    return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
  }

  Future<String?> _applicationRoot(String platform) async {
    if (rootPathOverride != null) return rootPathOverride;
    if (platform == 'ios') {
      final root = await channel.invokeMethod<dynamic>('applicationRoot');
      return root is String && root.trim().isNotEmpty ? root : null;
    }
    if (platform == 'windows') {
      return File(Platform.resolvedExecutable).parent.path;
    }
    return null;
  }

  Future<IntegrityResult> _checkManifest(String platform) async {
    if (publicKeyBytes.length != 32) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    final rootPath = await _applicationRoot(platform);
    if (rootPath == null) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    final root = Directory(rootPath);
    final manifestFile = File(
      '${root.path}${Platform.pathSeparator}$integrityFileName',
    );
    if (!await manifestFile.exists()) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    final envelope = object(jsonDecode(await manifestFile.readAsString()));
    final payloadText = envelope['payload'];
    final signatureText = envelope['signature'];
    if (payloadText is! String || signatureText is! String) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    late final Uint8List payloadBytes, signatureBytes;
    try {
      payloadBytes = Uint8List.fromList(base64.decode(payloadText));
      signatureBytes = Uint8List.fromList(base64.decode(signatureText));
    } on FormatException {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    if (signatureBytes.length != 64) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    final signature = Signature(
      signatureBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    );
    if (!await Ed25519().verify(payloadBytes, signature: signature)) {
      return const IntegrityResult(verified: false, detail: '无法验证为官方发布版本');
    }
    final payload = object(jsonDecode(utf8.decode(payloadBytes)));
    final validation = _validatePayload(payload, platform);
    if (validation != null) {
      return IntegrityResult(verified: false, detail: validation);
    }
    final files = payload['files'] as List<dynamic>;
    for (final entry in files) {
      final item = object(entry);
      final path = str(item['path']);
      final algorithm = str(item['algorithm']);
      final expected = str(item['sha256']).toLowerCase();
      final file = await _safeFile(root, path);
      if (file == null || !await file.exists()) {
        return const IntegrityResult(verified: false, detail: '程序文件完整性校验未通过');
      }
      final actual = algorithm == 'sha256'
          ? await _sha256(await file.readAsBytes())
          : algorithm == 'macho-sections-v1'
          ? await _machoHash(await file.readAsBytes())
          : null;
      if (actual == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected) ||
          actual != expected) {
        return const IntegrityResult(verified: false, detail: '程序文件完整性校验未通过');
      }
    }
    return const IntegrityResult(verified: true);
  }

  String? _validatePayload(Map<String, dynamic> payload, String platform) {
    if (integer(payload['schema']) != 1 ||
        str(payload['app']) != AppInfo.name ||
        str(payload['platform']) != platform ||
        str(payload['version']) != AppInfo.version ||
        integer(payload['build']) != AppInfo.buildNumber) {
      return '无法验证为官方发布版本';
    }
    final rawFiles = payload['files'];
    if (rawFiles is! List || rawFiles.isEmpty) return '无法验证为官方发布版本';
    final seen = <String>{};
    for (final entry in rawFiles) {
      if (entry is! Map) return '无法验证为官方发布版本';
      final item = object(entry);
      final path = str(item['path']);
      final algorithm = str(item['algorithm']);
      final digest = str(item['sha256']).toLowerCase();
      final duplicateKey = platform == 'windows' ? path.toLowerCase() : path;
      if (!_validRelativePath(path) ||
          path == integrityFileName ||
          !seen.add(duplicateKey) ||
          !{'sha256', 'macho-sections-v1'}.contains(algorithm) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        return '无法验证为官方发布版本';
      }
    }
    return null;
  }

  bool _validRelativePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains(':') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
      return false;
    }
    final parts = path.split('/');
    return parts.every(
      (part) => part.isNotEmpty && part != '.' && part != '..',
    );
  }

  Future<File?> _safeFile(Directory root, String relative) async {
    if (!_validRelativePath(relative)) return null;
    final file = File(
      '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    try {
      final rootReal = await root.resolveSymbolicLinks();
      final fileReal = await file.resolveSymbolicLinks();
      final prefix = rootReal.endsWith(Platform.pathSeparator)
          ? rootReal
          : '$rootReal${Platform.pathSeparator}';
      final comparedFile = _platform == 'windows'
          ? fileReal.toLowerCase()
          : fileReal;
      final comparedPrefix = _platform == 'windows'
          ? prefix.toLowerCase()
          : prefix;
      if (!comparedFile.startsWith(comparedPrefix)) return null;
      return File(fileReal);
    } on FileSystemException {
      return null;
    }
  }

  Future<String> _sha256(List<int> bytes) async => (await Sha256().hash(
    bytes,
  )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  /// Exposes the canonical Mach-O digest to deterministic package tests.
  /// This does not bypass manifest or signature checks in [check].
  Future<String?> machoDigestForTesting(List<int> bytes) => _machoHash(bytes);

  Future<String?> _machoHash(List<int> bytes) async {
    try {
      var data = Uint8List.fromList(bytes);
      final view = ByteData.sublistView(data);
      if (data.length >= 8) {
        final magic = view.getUint32(0, Endian.big);
        if (magic == 0xcafebabe || magic == 0xcafebabf) {
          final count = view.getUint32(4, Endian.big);
          if (count != 1 || data.length < (magic == 0xcafebabe ? 28 : 40)) {
            return null;
          }
          final cpu = view.getUint32(8, Endian.big);
          if (cpu != 0x0100000c) return null;
          final offset = magic == 0xcafebabe
              ? view.getUint32(16, Endian.big)
              : view.getUint64(16, Endian.big);
          final size = magic == 0xcafebabe
              ? view.getUint32(20, Endian.big)
              : view.getUint64(24, Endian.big);
          // FAT32 entries are cputype, cpusubtype, offset, size, align.
          // FAT64 entries use uint64 offset/size at the same logical fields.
          final entryEnd = magic == 0xcafebabe ? 28 : 40;
          if (offset > data.length ||
              size > data.length - offset ||
              entryEnd > data.length) {
            return null;
          }
          data = data.sublist(offset, offset + size);
        }
      }
      final thin = ByteData.sublistView(data);
      if (data.length < 32 || thin.getUint32(0, Endian.little) != 0xfeedfacf) {
        return null;
      }
      final ncmds = thin.getUint32(16, Endian.little);
      final sizeofcmds = thin.getUint32(20, Endian.little);
      if (ncmds > 4096 || sizeofcmds > data.length - 32) {
        return null;
      }
      final canonicalHeader = Uint8List.fromList(data.sublist(0, 32));
      canonicalHeader.fillRange(16, 24, 0);
      final canonical = BytesBuilder(copy: false)
        ..add(utf8.encode('ykt_helper-macho-sections-v1\u0000'))
        ..add(canonicalHeader);
      final commandEnd = 32 + sizeofcmds;
      var offset = 32;
      final sections = <({int offset, int size})>[];
      for (var index = 0; index < ncmds; index++) {
        if (offset > commandEnd - 8) {
          return null;
        }
        final commandView = ByteData.sublistView(data, offset);
        final command = commandView.getUint32(0, Endian.little);
        final commandSize = commandView.getUint32(4, Endian.little);
        if (commandSize < 8 || commandSize > commandEnd - offset) {
          return null;
        }
        final commandBytes = Uint8List.fromList(
          data.sublist(offset, offset + commandSize),
        );
        if (command == 0x19) {
          if (commandSize < 72) {
            return null;
          }
          final commandData = ByteData.sublistView(commandBytes);
          final sectionCount = commandData.getUint32(64, Endian.little);
          if (sectionCount > (commandSize - 72) ~/ 80 ||
              72 + sectionCount * 80 > commandSize) {
            return null;
          }
          final segmentName = utf8
              .decode(commandBytes.sublist(8, 24), allowMalformed: true)
              .split('\u0000')
              .first;
          if (segmentName == '__LINKEDIT') {
            commandBytes.fillRange(32, 40, 0);
            commandBytes.fillRange(48, 56, 0);
          }
          for (var section = 0; section < sectionCount; section++) {
            final sectionOffset = offset + 72 + section * 80;
            final sectionData = ByteData.sublistView(data, sectionOffset);
            final sectionSize = sectionData.getUint64(40, Endian.little);
            final fileOffset = sectionData.getUint32(48, Endian.little);
            final flags = sectionData.getUint32(64, Endian.little);
            final sectionType = flags & 0xff;
            if (sectionSize != 0 &&
                sectionType != 1 &&
                sectionType != 0x0c &&
                sectionType != 0x12) {
              if (fileOffset > data.length ||
                  sectionSize > data.length - fileOffset) {
                return null;
              }
              sections.add((offset: fileOffset, size: sectionSize));
            }
          }
        }
        if (command != 0x1d && command != 0x2b) {
          final sizeBytes = ByteData(4)
            ..setUint32(0, commandSize, Endian.little);
          canonical.add(sizeBytes.buffer.asUint8List());
          canonical.add(commandBytes);
        }
        offset += commandSize;
      }
      if (offset != commandEnd) return null;
      for (final section in sections) {
        canonical.add(
          data.sublist(section.offset, section.offset + section.size),
        );
      }
      final digest = await Sha256().hash(canonical.takeBytes());
      return digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }
}

Map<String, dynamic> object(dynamic value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};
String str(dynamic value) => value?.toString() ?? '';
int integer(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse(str(value)) ?? fallback;
