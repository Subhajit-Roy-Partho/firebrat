#!/usr/bin/env python3
"""Reject minified APK/AABs missing Java classes resolved by ONNX Runtime JNI."""
import struct
import sys
import zipfile

REQUIRED = {
    'Lai/onnxruntime/TensorInfo;',
    'Lai/onnxruntime/OnnxTensor;',
    'Lai/onnxruntime/OnnxJavaType;',
    'Lai/onnxruntime/OrtSession;',
    'Lai/onnxruntime/OrtException;',
}


def defined_classes(dex):
    if not dex.startswith(b'dex\n'):
        raise ValueError('Expected standard Android DEX')
    u32 = lambda offset: struct.unpack_from('<I', dex, offset)[0]
    strings = u32(60)
    types = u32(68)
    count, classes = u32(96), u32(100)
    result = set()
    for i in range(count):
        type_index = u32(classes + i * 32)
        string_index = u32(types + type_index * 4)
        offset = u32(strings + string_index * 4)
        # Skip the ULEB128 UTF-16 length before the MUTF-8 descriptor.
        while dex[offset] & 0x80:
            offset += 1
        offset += 1
        result.add(dex[offset:dex.index(b'\0', offset)].decode('utf-8'))
    return result


def main(path):
    found = set()
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.endswith('.dex'):
                found.update(defined_classes(archive.read(name)))
    missing = REQUIRED - found
    if missing:
        raise SystemExit('Missing unrenamed ONNX JNI classes: ' + ', '.join(sorted(missing)))
    print(f'Verified {len(REQUIRED)} ONNX JNI class definitions in {path}')


if __name__ == '__main__':
    main(sys.argv[1])
