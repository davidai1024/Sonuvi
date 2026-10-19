#!/usr/bin/env python3
"""Create a relocatable offline payload from an owned standalone runtime."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess

VOICES = tuple('af_heart af_bella af_nicole af_alloy af_aoede af_jessica af_kore af_nova af_river af_sarah af_sky am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck am_santa bf_emma bf_alice bf_isabella bf_lily bm_george bm_daniel bm_fable bm_lewis'.split())
MODEL_REVISION = 'a71e4d38b236d968966a2002c4c895dbd12b1c3c'


def package(source_root, destination):
    source_root = source_root.resolve()
    ready = json.loads((source_root/'ready.json').read_text())
    runtime = Path(ready['python']).resolve().parent.parent
    model = Path(ready['model']).resolve()
    if not runtime.is_relative_to(source_root) or not model.is_relative_to(source_root):
        raise RuntimeError('Use an independently owned environment')
    if (runtime/'pyvenv.cfg').exists():
        raise RuntimeError('Virtual environments cannot be bundled: standalone Python required')
    destination.mkdir(parents=True, exist_ok=False)
    subprocess.run(['/bin/cp', '-cR', str(runtime), str(destination/'runtime')], check=True)
    for path in sorted((destination/'runtime').rglob('__pycache__'), reverse=True):
        shutil.rmtree(path)
    for path in (destination/'runtime').rglob('*'):
        if path.is_symlink() and (os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(destination.resolve())):
            raise RuntimeError('Runtime contains an external link')
        if path.is_file() and path.suffix in ('.pyc', '.pyo'):
            path.unlink()
    # Console entry points are not used by the app. Remove build-machine
    # shebang paths so the payload never points at the original Speak11 venv.
    for script in (destination/'runtime/bin').iterdir():
        if script.is_symlink() or not script.is_file():
            continue
        with script.open('rb') as stream:
            head = stream.read(2)
        if head == b'#!':
            lines = script.read_bytes().split(b'\n', 1)
            if b'python' in lines[0] and len(lines) == 2:
                script.write_bytes(b'#!/usr/bin/env python3\n' + lines[1])
    target = destination/'model'; target.mkdir()
    for name in ['config.json','kokoro-v1_0.safetensors','README.md','VOICES.md']:
        shutil.copy2(model/name, target/name)
    (target/'voices').mkdir()
    for voice in VOICES:
        shutil.copy2(model/'voices'/(voice+'.safetensors'), target/'voices'/(voice+'.safetensors'))
    license_path = Path(__file__).resolve().parents[1]/'Resources/UV-LICENSE-APACHE'
    shutil.copy2(license_path, target/'LICENSE-APACHE-2.0.txt')
    (target/'NOTICE.txt').write_text('Kokoro 82M, MLX conversion by mlx-community. Apache-2.0.\nhttps://huggingface.co/hexgrad/Kokoro-82M\nhttps://huggingface.co/mlx-community/Kokoro-82M-bf16\nRevision: '+MODEL_REVISION+'\nAll 28 English voices are included (20 American, 8 British).\n')
    packages = []
    for site in (destination/'runtime/lib').glob('python*/site-packages'):
        packages.extend({'name': d.metadata.get('Name', ''), 'version': d.version} for d in importlib.metadata.distributions(path=[str(site)]))
    (destination/'dependencies.json').write_text(json.dumps(sorted(packages, key=lambda x:x['name'].lower()), indent=2))
    (destination/'manifest.json').write_text(json.dumps({'format':1,'architecture':'arm64','minimum_macos':'26.2','model':'mlx-community/Kokoro-82M-bf16','revision':MODEL_REVISION,'voices':list(VOICES)}, indent=2))
    print(json.dumps({'payload':str(destination),'dependencies':len(packages),'voices':len(VOICES)}))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--source-root',type=Path,required=True); parser.add_argument('--destination',type=Path,required=True)
    args=parser.parse_args(); package(args.source_root,args.destination)
