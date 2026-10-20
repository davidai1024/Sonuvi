"""Install a relocated payload, then synthesize all English voices offline.

Run on a Mac with GPU access. No playback or changes to user preferences.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    resources = Path(__file__).resolve().parents[1] / 'Resources'
    with tempfile.TemporaryDirectory(prefix='sv14-', dir='/tmp') as folder:
        root = Path(folder).resolve()
        env = dict(os.environ, HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                   HF_HOME=str(root/'Cache'), PYTHONDONTWRITEBYTECODE='1')
        subprocess.run([str(bundle/'runtime/bin/python3'), '-I', str(resources/'runtime_setup.py'),
                        '--root', str(root), '--uv', str(resources/'uv'), '--mode', 'bundled',
                        '--bundle', str(bundle)], env=env, check=True, timeout=90)
        ready = json.loads((root/'ready.json').read_text())
        assert ready['runtimeRevision'] == 'mlx-0.32.4-macos14-v1'
        assert Path(ready['python']).is_relative_to(root)
        voices = json.loads((bundle/'manifest.json').read_text())['voices']
        assert len(voices) == 28
        proc = subprocess.Popen([ready['python'], '-I', str(resources/'kokoro_service.py'),
                                 '--root', str(root)], env=env)
        results = []
        try:
            for _ in range(200):
                if (root/'tts.sock').exists():
                    break
                if proc.poll() is not None:
                    raise RuntimeError('Service exited')
                time.sleep(.05)
            for voice in voices:
                start = time.monotonic()
                with socket.socket(socket.AF_UNIX) as sock:
                    sock.settimeout(90)
                    sock.connect(str(root/'tts.sock'))
                    sock.sendall(json.dumps(dict(text='Hello, this is Sonuvi. Read naturally, wherever you work.',
                                                voice=voice, speed=1)).encode()+b'\n')
                    data = bytearray()
                    while b'\n' not in data:
                        chunk = sock.recv(4096)
                        if not chunk:
                            raise RuntimeError('Service closed without response')
                        data.extend(chunk)
                reply = json.loads(data)
                assert reply['status'] == 'ok', reply
                with wave.open(reply['audio_file']) as audio:
                    seconds = audio.getnframes() / audio.getframerate()
                    assert audio.getframerate() == 24000 and seconds > 1
                    assert any(audio.readframes(audio.getnframes())), 'Silent audio'
                Path(reply['audio_file']).unlink()
                row = dict(voice=voice, audio_seconds=round(seconds, 3), elapsed=round(time.monotonic()-start, 3))
                results.append(row)
                print(json.dumps(row), flush=True)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
        report = dict(passed=True, offline=True, relocated=True, minimum_macos='14.0',
                      tested_host=os.uname().release, voices=len(results), synthesis=results,
                      limitation='macOS 14/15 hardware regression not performed')
        args.report.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
