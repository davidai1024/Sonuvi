#!/usr/bin/env python3
"""Create an immutable, self-contained downloadable voice pack. GPL-3.0."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile


def package(source, destination, sequence):
    manifest = json.loads((source / 'manifest.json').read_text())
    assert manifest['architecture'] == 'arm64' and len(manifest['voices']) == 28
    manifest['package_version'] = sequence
    entries = [p for p in sorted(source.rglob('*')) if '__pycache__' not in p.parts and p.suffix not in ('.pyc', '.pyo')]
    expanded = 0
    with tarfile.open(destination, 'w:gz', dereference=True, compresslevel=6) as archive:
        for path in entries:
            if path.is_dir():
                continue
            if path.is_symlink() and not path.resolve().is_relative_to(source.resolve()):
                raise ValueError('External symlink in voice payload')
            if not path.is_file():
                raise ValueError('Unsupported payload file')
            name = 'VoicePack/' + path.relative_to(source).as_posix()
            if path.name == 'manifest.json' and path.parent == source:
                import io
                data = json.dumps(manifest, sort_keys=True).encode()
                item = tarfile.TarInfo(name); item.size = len(data); item.mode = 0o644
                archive.addfile(item, io.BytesIO(data)); expanded += len(data)
            else:
                archive.add(path, arcname=name, recursive=False); expanded += path.stat().st_size
    h = hashlib.sha256()
    with destination.open('rb') as f:
        for data in iter(lambda: f.read(1024 * 1024), b''): h.update(data)
    return {'format': 1, 'sequence': sequence, 'packageVersion': str(sequence), 'architecture': 'arm64',
            'minimumMacOS': '14.0', 'minimumAppVersion': '0.4.22',
            'runtimeRevision': manifest['runtime_revision'], 'modelRevision': manifest['revision'],
            'voices': manifest['voices'], 'bytes': destination.stat().st_size, 'expandedBytes': expanded,
            'sha256': h.hexdigest(), 'downloadURL': 'https://github.com/davidai1024/Sonuvi/releases/download/voice-kokoro-en-v' + str(sequence) + '/' + destination.name}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True); parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--sequence', type=int, required=True); args = parser.parse_args()
    result = package(args.source, args.output, args.sequence)
    args.catalog.write_text(json.dumps(result, sort_keys=True, separators=(',', ':')) + '\n')
    print(json.dumps({'bytes': result['bytes'], 'sha256': result['sha256'], 'sequence': result['sequence']}))
