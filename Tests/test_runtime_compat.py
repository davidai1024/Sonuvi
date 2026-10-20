import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('compat', Path(__file__).parents[1] / 'Resources/runtime_compat.py')
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)


def macho(major, minor=0, legacy=False):
    minimum = (major << 16) | (minor << 8)
    command = (struct.pack('<4I', 0x24, 16, minimum, minimum) if legacy else
               struct.pack('<6I', 0x32, 24, 1, minimum, 0x1a0500, 0))
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 6, 1, len(command), 0, 0) + command


class CompatibilityTests(unittest.TestCase):
    def test_new_sdk_does_not_raise_deployment_floor(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'core.so').write_bytes(macho(14))
            self.assertEqual(compat.validate_tree(root)['arm64_binaries_checked'], 1)

    def test_mislabeled_wheel_cannot_hide_too_new_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'macosx_14_0_libmlx.dylib').write_bytes(macho(26, 2))
            with self.assertRaisesRegex(ValueError, '26.2.0'):
                compat.validate_tree(root)

    def test_legacy_and_universal_arm64_targets_are_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'universal.dylib'
            header = struct.pack('>7I', 0xcafebabe, 1, 0x100000c, 0, 4096, 48, 12)
            path.write_bytes(header.ljust(4096, b'\0') + macho(11, legacy=True))
            self.assertEqual(compat.deployment_targets(path), [(11, 0, 0)])

    def test_empty_payload_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, 'No arm64'):
                compat.validate_tree(Path(folder))


if __name__ == '__main__':
    unittest.main()
