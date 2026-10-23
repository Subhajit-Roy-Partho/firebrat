"""Check 64-bit ELF load-segment alignment inside an Android AAB/APK.

This checks native binaries, not APK ZIP alignment or runtime behavior.
"""
import argparse
import struct
import sys
import zipfile


def check_archive(path):
    checked = 0
    errors = []
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if not name.endswith('.so') or not any(
                f'lib/{abi}/' in name for abi in ('arm64-v8a', 'x86_64')
            ):
                continue
            checked += 1
            data = archive.read(name)
            if data[:5] != b'\x7fELF\x02':
                errors.append(f'{name}: invalid 64-bit ELF')
                continue
            endian = '<' if data[5] == 1 else '>'
            offset = struct.unpack_from(endian + 'Q', data, 32)[0]
            size, count = struct.unpack_from(endian + 'HH', data, 54)
            loads = 0
            for index in range(count):
                header = offset + index * size
                kind = struct.unpack_from(endian + 'I', data, header)[0]
                if kind == 1:
                    loads += 1
                    alignment = struct.unpack_from(endian + 'Q', data, header + 48)[0]
                    if alignment < 16384:
                        errors.append(f'{name}: LOAD alignment {alignment} is below 16384')
                        break
            if not loads:
                errors.append(f'{name}: missing LOAD segments')
    if not checked:
        errors.append('No 64-bit native libraries found')
    return checked, errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    args = parser.parse_args()
    checked, errors = check_archive(args.archive)
    print(f'Checked {checked} 64-bit native libraries')
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(bool(errors))
