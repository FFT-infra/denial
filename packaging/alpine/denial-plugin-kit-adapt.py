#!/usr/bin/env python3
"""Adapt staged compiler executables for Alpine, retaining manifest integrity.

Only package staging may call this helper. Runtime sources and the raw engine
remain byte-identical: their identity is also checked by native activation.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import struct


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def adapt_executable(path, *, appended_snapshot=False):
    # Dart's executable format appends an ELF snapshot followed by a little-
    # endian offset and magic. patchelf can move that trailer away from EOF.
    # Patch only the runtime, then append the unchanged payload at a 64K boundary
    # (the pinned SDK's dart2native.writeAppendedExecutable convention).
    payload = None
    magic = bytes.fromhex('dcdcf6f600000000')
    if appended_snapshot:
        original = path.read_bytes()
        assert original[-8:] == magic, 'Unsupported Dart executable trailer'
        offset = struct.unpack('<Q', original[-16:-8])[0]
        assert 0 < offset < len(original) - 16 and offset % 65536 == 0
        payload = original[offset:-16]
        assert payload[:4] == b'\x7fELF', 'Expected an ELF AOT snapshot'
        path.write_bytes(original[:offset])
    old_rpath = subprocess.check_output(
        ['patchelf', '--print-rpath', str(path)], text=True).strip()
    rpath = ':'.join(filter(None, [old_rpath, '/usr/lib/denial/alpine']))
    subprocess.run([
        'patchelf', '--set-rpath', rpath,
        '--add-needed', 'libgcompat.so.0',
        '--add-needed', 'libdenial-resolver-bridge.so.0',
        '--add-needed', 'libdenial-pthread-stack.so.0', str(path),
    ], check=True)
    if payload is not None:
        size = path.stat().st_size
        padding = (-size) % 65536
        with path.open('ab') as stream:
            stream.write(bytes(padding))
            stream.write(payload)
            stream.write(struct.pack('<Q', size + padding))
            stream.write(magic)


def main():
    kit = Path(sys.argv[1]).resolve(strict=True)
    manifest_file = kit / 'kit.json'
    manifest = json.loads(manifest_file.read_text())
    assert manifest['schema'] == 1
    # Reject changed/traversing inputs before doing any adaptation.
    for name, expected in manifest['files'].items():
        path = kit / name
        assert path.resolve().is_relative_to(kit), name
        assert not path.is_symlink() and digest(path) == expected, name
    for name, target in manifest['links'].items():
        path = kit / name
        assert path.resolve().is_relative_to(kit), name
        assert str(path.readlink()) == target, name
    for name in manifest['files']:
        if not name.startswith(('flutter/bin/', 'engine/out/')):
            continue
        path = kit / name
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        interpreter = subprocess.run(
            ['patchelf', '--print-interpreter', str(path)],
            capture_output=True, text=True)
        if interpreter.returncode:
            continue  # Shared libraries and AOT data have no program interpreter.
        adapt_executable(path)
        manifest['files'][name] = digest(path)
        print(f'Adapted {name}')
    manifest_file.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    adapt_executable(Path(sys.argv[2]), appended_snapshot=True)


if __name__ == '__main__':
    main()
