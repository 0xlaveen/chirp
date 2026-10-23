#!/usr/bin/env python3
"""16 KB page-alignment gate for packaged APKs (Android 15+ devices may use 16 KB pages).

For every .apk argument (or every .apk under a directory argument) it verifies that
  1. every packaged lib/<abi>/*.so has only PT_LOAD segments aligned to >= 16384 bytes, and
  2. the zip layout matches zipalign -P 16: stored entries are 4-byte aligned, and a stored
     (uncompressed) .so entry's data starts on a 16384-byte boundary.
Deflated .so entries (legacy packaging) are extracted at install time, where check 1 is the
load-time gate. Prints sizes and alignment values only; exits non-zero on any violation or
when no APK is found. Usage: check-native-alignment.py <apk-or-dir> [...]
"""
import struct
import sys
import zipfile
from pathlib import Path

PAGE = 16384
PT_LOAD = 1


def load_segment_alignments(elf):
    if len(elf) < 64 or elf[:4] != b'\x7fELF' or elf[5] != 1:
        raise ValueError('not a little-endian ELF object')
    if elf[4] == 2:
        phoff, = struct.unpack_from('<Q', elf, 32)
        phentsize, phnum = struct.unpack_from('<HH', elf, 54)
        align_at, align_fmt = 48, '<Q'
    else:
        phoff, = struct.unpack_from('<I', elf, 28)
        phentsize, phnum = struct.unpack_from('<HH', elf, 42)
        align_at, align_fmt = 28, '<I'
    return [struct.unpack_from(align_fmt, elf, phoff + i * phentsize + align_at)[0]
            for i in range(phnum)
            if struct.unpack_from('<I', elf, phoff + i * phentsize)[0] == PT_LOAD]


def stored_data_offset(raw, info):
    raw.seek(info.header_offset)
    fixed = raw.read(30)
    if len(fixed) < 30 or fixed[:4] != b'PK\x03\x04':
        raise ValueError('bad local file header')
    name_len, extra_len = struct.unpack_from('<HH', fixed, 26)
    return info.header_offset + 30 + name_len + extra_len


def check_apk(path):
    problems = []
    with zipfile.ZipFile(path) as archive:
        native = {i.filename: i for i in archive.infolist()
                  if i.filename.startswith('lib/') and i.filename.endswith('.so')}
        for name, info in native.items():
            try:
                alignments = load_segment_alignments(archive.read(info))
            except ValueError as error:
                problems.append('%s: %s' % (name, error))
                continue
            if not alignments:
                problems.append('%s: no PT_LOAD segments' % name)
            for value in alignments:
                if value < PAGE:
                    problems.append('%s: PT_LOAD alignment %d < %d' % (name, value, PAGE))
            storage = 'stored' if info.compress_type == zipfile.ZIP_STORED else 'deflated, extracted at install'
            print('  %s: %d PT_LOAD, min alignment %d (%s)'
                  % (name, len(alignments), min(alignments, default=0), storage))
        with open(path, 'rb') as raw:
            for info in archive.infolist():
                if info.compress_type != zipfile.ZIP_STORED:
                    continue
                offset = stored_data_offset(raw, info)
                required = PAGE if info.filename in native else 4
                if offset % required:
                    problems.append('%s: stored offset %d not %d-byte aligned' % (info.filename, offset, required))
    print('  %s' % ('16 KB alignment OK' if not problems else 'FAIL: ' + '; '.join(problems)))
    return not problems


def main():
    paths = []
    for argument in sys.argv[1:]:
        path = Path(argument)
        paths += sorted(path.glob('*.apk')) if path.is_dir() else [path]
    if not paths:
        print('no APKs to check', file=sys.stderr)
        return 1
    ok = True
    for path in paths:
        print('%s (%d bytes)' % (path, path.stat().st_size))
        ok = check_apk(path) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
