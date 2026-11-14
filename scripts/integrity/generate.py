"""Create an authenticated runtime file inventory for official desktop/iOS builds.

The Ed25519 key comes only from INTEGRITY_SIGNING_KEY. A source build without a
key still runs, but cannot pass official-distribution verification.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys


PUBLIC_KEY = 'vw8vjofbMl9nlTDI7S2dJ0WL4l/b0ilC+KSdjNd7VWo='
MANIFEST = 'integrity.json'


def macho_digest(data: bytes) -> str:
    """Hash executable sections and stable headers, allowing normal re-signing."""
    if len(data) >= 28 and data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        if struct.unpack_from('>I', data, 4)[0] != 1 or struct.unpack_from('>I', data, 8)[0] != 0x100000C:
            raise ValueError('Expected one arm64 Mach-O slice')
        if data[:4] == b'\xca\xfe\xba\xbe':
            offset, size = struct.unpack_from('>II', data, 16)
        else:
            if len(data) < 40:
                raise ValueError('Truncated fat64 header')
            offset, size = struct.unpack_from('>QQ', data, 16)
        if offset + size > len(data):
            raise ValueError('Invalid fat Mach-O slice bounds')
        return macho_digest(data[offset:offset + size])
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected a little-endian 64-bit Mach-O')
    count, command_bytes = struct.unpack_from('<II', data, 16)
    if count > 4096 or 32 + command_bytes > len(data):
        raise ValueError('Invalid Mach-O command bounds')
    header = bytearray(data[:32])
    header[16:24] = bytes(8)
    digest = hashlib.sha256(b'ykt_helper-macho-sections-v1\0' + header)
    offset = 32
    sections = []
    for _ in range(count):
        if offset + 8 > 32 + command_bytes:
            raise ValueError('Truncated Mach-O command')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise ValueError('Invalid Mach-O command size')
        canonical = bytearray(data[offset:offset + size])
        if command == 0x19:
            if size < 72:
                raise ValueError('Truncated segment')
            section_count = struct.unpack_from('<I', canonical, 64)[0]
            if 72 + section_count * 80 > size:
                raise ValueError('Truncated section table')
            if canonical[8:24].split(b'\0')[0] == b'__LINKEDIT':
                canonical[32:40] = bytes(8)
                canonical[48:56] = bytes(8)
            for index in range(section_count):
                start = offset + 72 + index * 80
                section_size = struct.unpack_from('<Q', data, start + 40)[0]
                file_offset = struct.unpack_from('<I', data, start + 48)[0]
                flags = struct.unpack_from('<I', data, start + 64)[0]
                if section_size and flags & 0xFF not in (1, 0xC, 0x12):
                    if file_offset + section_size > len(data):
                        raise ValueError('Invalid Mach-O section bounds')
                    sections.append((file_offset, section_size))
        if command not in (0x1D, 0x2B):
            digest.update(struct.pack('<I', size))
            digest.update(canonical)
        offset += size
    if offset != 32 + command_bytes:
        raise ValueError('Invalid Mach-O command table')
    for file_offset, section_size in sections:
        digest.update(data[file_offset:file_offset + section_size])
    return digest.hexdigest()


def inventory(directory: Path, platform: str):
    files = []
    for file in sorted(directory.rglob('*')):
        name = file.relative_to(directory).as_posix()
        if name == MANIFEST or file.is_dir():
            continue
        if file.is_symlink():
            raise ValueError('Symlinks are not accepted in runtime inventory')
        if platform == 'ios' and (
            '_CodeSignature' in file.parts or
            file.name in ('embedded.mobileprovision', 'Info.plist') or
            'SC_Info' in file.parts
        ):
            continue
        content = file.read_bytes()
        macho = platform == 'ios' and content[:4] in (
            b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf',
        )
        algorithm = 'macho-sections-v1' if macho else 'sha256'
        value = macho_digest(content) if macho else hashlib.sha256(content).hexdigest()
        files.append({'path': name, 'algorithm': algorithm, 'sha256': value})
    if not files:
        raise ValueError('Cannot inventory an empty application')
    return files


def generate(directory: Path, platform: str, repository: Path):
    match = re.search(r'^version:\s*([^+\s]+)\+(\d+)\s*$', (repository / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Missing version/build')
    payload = json.dumps({
        'schema': 1, 'app': 'ykt_helper', 'platform': platform,
        'version': match[1], 'build': int(match[2]),
        'files': inventory(directory, platform),
    }, separators=(',', ':'), ensure_ascii=False).encode()
    encoded_key = os.environ.get('INTEGRITY_SIGNING_KEY', '').strip()
    signature = ''
    if encoded_key:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        key = serialization.load_pem_private_key(encoded_key.encode(), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError('Expected an Ed25519 distribution key')
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        if base64.b64encode(public).decode() != PUBLIC_KEY:
            raise ValueError('Distribution key does not match the embedded public key')
        signature = base64.b64encode(key.sign(payload)).decode()
    (directory / MANIFEST).write_text(json.dumps({
        'payload': base64.b64encode(payload).decode(), 'signature': signature,
    }, separators=(',', ':')), encoding='utf-8')
    print(f'Runtime inventory: {len(json.loads(payload)["files"])} files; authenticated={bool(signature)}')
    return directory / MANIFEST


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--platform', choices=('windows', 'ios'), required=True)
    arguments = parser.parse_args()
    generate(arguments.root.resolve(), arguments.platform, Path(__file__).resolve().parents[2])
