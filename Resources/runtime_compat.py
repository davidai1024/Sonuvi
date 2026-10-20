"""Inspect actual arm64 Mach-O deployment targets, not wheel filename tags."""
import argparse
import json
from pathlib import Path
import struct


def version(value):
    parts = tuple(map(int, value.split('.')))
    return (parts + (0, 0, 0))[:3]


def deployment_targets(path):
    with Path(path).open('rb') as stream:
        magic = stream.read(4)
        if magic == b'\xcf\xfa\xed\xfe':
            offsets = [0]
        elif magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            count = struct.unpack('>I', stream.read(4))[0]
            wide = magic[-1] == 0xbf
            fmt = '>IIQQII' if wide else '>IIIII'
            offsets = []
            for _ in range(count):
                arch = struct.unpack(fmt, stream.read(struct.calcsize(fmt)))
                if arch[0] == 0x100000c:
                    offsets.append(arch[2])
            if not offsets:
                raise ValueError('Mach-O has no arm64 slice: ' + str(path))
        else:
            return []
        targets = []
        for offset in offsets:
            stream.seek(offset)
            header = stream.read(32)
            if header[:4] != b'\xcf\xfa\xed\xfe':
                raise ValueError('Invalid arm64 Mach-O: ' + str(path))
            cpu, _, _, count, _, _, _ = struct.unpack('<7I', header[4:])
            if cpu != 0x100000c:
                raise ValueError('Mach-O has no arm64 slice: ' + str(path))
            for _ in range(count):
                command, size = struct.unpack('<II', stream.read(8))
                if size < 8:
                    raise ValueError('Invalid Mach-O command: ' + str(path))
                data = stream.read(size - 8)
                if command == 0x32:  # LC_BUILD_VERSION
                    platform, minimum = struct.unpack('<II', data[:8])
                    if platform != 1:
                        raise ValueError('Not a macOS binary: ' + str(path))
                elif command == 0x24:  # LC_VERSION_MIN_MACOSX
                    minimum = struct.unpack('<I', data[:4])[0]
                else:
                    continue
                targets.append((minimum >> 16, (minimum >> 8) & 255, minimum & 255))
        return targets


def validate_tree(root, minimum='14.0'):
    checked = 0
    too_new = []
    for path in sorted(Path(root).rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        for target in deployment_targets(path):
            checked += 1
            if target > version(minimum):
                too_new.append(str(path.relative_to(root)) + ': macOS ' + '.'.join(map(str, target)))
    if too_new:
        raise ValueError('Binaries exceed macOS ' + minimum + ':\n' + '\n'.join(too_new))
    if not checked:
        raise ValueError('No arm64 Mach-O binaries found in ' + str(root))
    return {'minimum_macos': minimum, 'arm64_binaries_checked': checked}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--minimum', default='14.0')
    args = parser.parse_args()
    print(json.dumps(validate_tree(args.root, args.minimum)))
