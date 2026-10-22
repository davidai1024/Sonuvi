#!/usr/bin/env python3
"""Fetch one pinned official Sparkle distribution; verify before extracting."""
from pathlib import Path
import hashlib, shutil, subprocess, tarfile

VERSION = '2.10.0'
SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
root = Path(__file__).resolve().parent.parent / 'build' / ('Sparkle-' + VERSION)
archive = root.parent / ('Sparkle-' + VERSION + '.tar.xz')
root.parent.mkdir(parents=True, exist_ok=True)
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
    temporary = archive.with_suffix('.download')
    subprocess.run(['/usr/bin/curl', '--fail', '--location', '--retry', '3', '--output', str(temporary),
                    f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{archive.name}'], check=True)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
        temporary.unlink(missing_ok=True)
        raise SystemExit('Sparkle download hash mismatch')
    temporary.replace(archive)
if not (root / '.verified').exists():
    if root.exists(): shutil.rmtree(root)
    root.mkdir()
    # Verified upstream archive, with framework symlinks preserved by tar.
    subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(root)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(root / 'Sparkle.framework')], check=True)
    (root / '.verified').write_text(SHA256)
print(root)
