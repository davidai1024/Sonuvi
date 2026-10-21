import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('setup',Path(__file__).parents[1]/'Resources/runtime_setup.py')
setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)

class BundledRuntimeTests(unittest.TestCase):
    def fixture(self, parent):
        bundle=parent/'bundle';(bundle/'runtime/bin').mkdir(parents=True);(bundle/'model').mkdir()
        (bundle/'manifest.json').write_text('{"format":1,"architecture":"arm64"}')
        (bundle/'runtime/bin/python3').write_text('fixture')
        (bundle/'model/config.json').write_text('{}')
        (bundle/'model/kokoro-v1_0.safetensors').write_bytes(b'fixture')
        return bundle
    def install(self, root, bundle):
        args=['setup','--root',str(root),'--uv',str(root/'uv'),'--mode','bundled','--bundle',str(bundle)]
        with patch.object(sys,'argv',args),contextlib.redirect_stdout(io.StringIO()):setup.main()
    def test_relocation_writes_new_local_paths_and_retains_bundle(self):
        with tempfile.TemporaryDirectory() as f:
            parent=Path(f).resolve();bundle=self.fixture(parent);root=parent/'another-machine'
            with patch.object(setup,'verify') as verify:self.install(root,bundle)
            info=json.loads((root/'ready.json').read_text())
            self.assertEqual(info['source'],'bundled')
            self.assertEqual(info['runtimeRevision'], setup.RUNTIME_REVISION)
            self.assertTrue(Path(info['python']).is_relative_to(root))
            self.assertTrue(Path(info['model']).is_relative_to(root))
            self.assertNotIn(str(bundle),json.dumps(info))
            self.assertTrue((bundle/'runtime/bin/python3').exists())
            self.assertTrue(Path(info['python']).exists());verify.assert_called_once()
    def test_external_symlink_rejected_without_replacing_working_marker(self):
        with tempfile.TemporaryDirectory() as f:
            parent=Path(f).resolve();bundle=self.fixture(parent);root=parent/'target';root.mkdir()
            (parent/'external').write_text('outside');(bundle/'runtime/external').symlink_to(parent/'external')
            marker='{"source":"keep-existing"}';(root/'ready.json').write_text(marker)
            with self.assertRaisesRegex(RuntimeError,'外部链接'):self.install(root,bundle)
            self.assertEqual((root/'ready.json').read_text(),marker)
    def test_nonrelocatable_virtual_environment_is_rejected(self):
        with tempfile.TemporaryDirectory() as f:
            parent=Path(f).resolve();bundle=self.fixture(parent)
            (bundle/'runtime/pyvenv.cfg').write_text('home = /original-machine/python')
            with self.assertRaisesRegex(RuntimeError,'独立环境'):self.install(parent/'target',bundle)
    def test_wrong_architecture_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as f:
            parent=Path(f).resolve();bundle=self.fixture(parent)
            (bundle/'manifest.json').write_text('{"format":1,"architecture":"x86_64"}')
            with patch.object(setup,'clone_tree') as clone:
                with self.assertRaisesRegex(RuntimeError,'格式不支持'):self.install(parent/'target',bundle)
                clone.assert_not_called()

    def test_incompatible_dependencies_preserve_existing_installation(self):
        with tempfile.TemporaryDirectory() as f:
            parent=Path(f).resolve();bundle=self.fixture(parent);root=parent/'target';root.mkdir()
            marker='{"source":"keep-existing"}';(root/'ready.json').write_text(marker)
            with patch.object(setup,'verify',side_effect=ValueError('Binaries exceed macOS 14.0')):
                with self.assertRaisesRegex(ValueError,'exceed'):self.install(root,bundle)
            self.assertEqual((root/'ready.json').read_text(),marker)


class DownloadablePackTests(BundledRuntimeTests):
    def test_downloaded_pack_records_independent_version(self):
        with tempfile.TemporaryDirectory() as f:
            parent = Path(f).resolve(); bundle = self.fixture(parent); root = parent/'fresh'
            manifest = json.loads((bundle/'manifest.json').read_text())
            manifest.update(package_version=2, runtime_revision='runtime-v2', revision='model-v2')
            (bundle/'manifest.json').write_text(json.dumps(manifest))
            with patch.object(setup, 'verify'): self.install(root, bundle)
            info = json.loads((root/'ready.json').read_text())
            self.assertEqual(info['packageVersion'], 2)
            self.assertEqual(info['runtimeRevision'], 'runtime-v2')
            self.assertEqual(info['modelRevision'], 'model-v2')

    def test_failed_model_update_keeps_last_working_generation(self):
        with tempfile.TemporaryDirectory() as f:
            parent = Path(f).resolve(); bundle = self.fixture(parent); root = parent/'existing'; root.mkdir()
            marker = json.dumps({'packageVersion': 1, 'python': 'keep', 'model': 'keep'})
            (root/'ready.json').write_text(marker)
            with patch.object(setup, 'verify', side_effect=RuntimeError('incompatible update')):
                with self.assertRaises(RuntimeError): self.install(root, bundle)
            self.assertEqual((root/'ready.json').read_text(), marker)

    def test_cancellation_reclaims_partial_files_without_deleting_active_model(self):
        with tempfile.TemporaryDirectory() as f:
            parent = Path(f).resolve(); bundle = self.fixture(parent); root = parent/'existing'; root.mkdir()
            live = root/'install-live'; (live/'runtime/bin').mkdir(parents=True)
            marker = json.dumps({'python': str(live/'runtime/bin/python3'), 'packageVersion': 1})
            (root/'ready.json').write_text(marker)
            with patch.object(setup, 'verify', side_effect=SystemExit(130)):
                with self.assertRaises(SystemExit): self.install(root, bundle)
            self.assertEqual((root/'ready.json').read_text(), marker)
            self.assertTrue(live.is_dir())
            self.assertFalse(list(root.glob('installation-*.partial')))

if __name__=='__main__':unittest.main()
