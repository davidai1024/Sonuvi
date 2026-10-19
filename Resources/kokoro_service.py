#!/usr/bin/env python3
"""Sonuvi local-only Kokoro service. GPL-3.0."""
import argparse
import fcntl
import json
import os
import re
from pathlib import Path
import select
import signal
import socket
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    ready = json.loads((root / "ready.json").read_text())
    lock = (root / "service.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    sock_path = root / "tts.sock"
    if sock_path.exists():
        sock_path.unlink()
    os.umask(0o077)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(sock_path)); listener.listen(4); listener.settimeout(3)
    generation = threading.Lock()
    last_use = [time.monotonic()]
    audio_root = root / "Audio"
    audio_root.mkdir(exist_ok=True)

    engine = {}
    warmed_languages = set()

    def load_engine():
        # Called only under generation. Bind the socket first so warmup and
        # foreground clients share one initialization, even on a cold launch.
        if engine:
            return
        import espeakng_loader
        pronunciation = root / "espeak-ng-data"
        if pronunciation.is_dir():
            espeakng_loader.get_data_path = lambda: str(pronunciation)
        from mlx_audio.tts.utils import load_model
        from mlx_audio.audio_io import write
        import numpy as np
        model = load_model(ready["model"], model_type="kokoro")
        engine.update(model=model, write=write, np=np)

    def gone(client):
        try:
            readable, _, _ = select.select([client], [], [], 0)
            return bool(readable and not client.recv(1, socket.MSG_PEEK))
        except OSError:
            return True

    def handle(client):
        last_use[0] = time.monotonic()
        out = None
        try:
            client.settimeout(10)
            data = bytearray()
            while b"\n" not in data:
                chunk = client.recv(8192)
                if not chunk:
                    return
                data.extend(chunk)
                if len(data) > 100_000:
                    return
            req = json.loads(data)
            if req.get("action") == "capabilities":
                client.sendall(b'{"status":"ok","voice_protocol":2,"engine_protocol":3}\n'); return
            if req.get("action") == "shutdown":
                client.sendall(b'{"status":"ok"}\n'); client.close()
                sock_path.unlink(missing_ok=True); os._exit(0)
            warming = req.get("action") == "warmup"
            text = "Welcome to Sonuvi. Your local reading voice is ready." if warming else req.get("text", "")
            if not isinstance(text, str) or not text.strip() or len(text) > 6000:
                raise ValueError("Invalid text")
            voice = req.get("voice", "af_heart")
            if not isinstance(voice, str) or not re.fullmatch(r"[ab][fm]_[a-z]+", voice):
                voice = "af_heart"
            voice_path = Path(ready["model"]) / "voices" / (voice + ".safetensors")
            if not voice_path.is_file():
                raise ValueError("Voice file not installed")
            speed = min(2, max(0.5, float(req.get("speed", 1))))
            with generation:
                if gone(client):
                    return
                language = "b" if voice.startswith("b") else "a"
                if warming and language in warmed_languages:
                    client.sendall(b'{"status":"ok","warmed":true}\n'); return
                load_engine()
                model, np, write = engine["model"], engine["np"], engine["write"]
                segments = []
                rate = 24000
                for part in model.generate(text=text, voice=str(voice_path), speed=speed, lang_code="b" if voice.startswith("b") else "a"):
                    if gone(client):
                        return
                    segments.append(np.array(part.audio)); rate = part.sample_rate
                if not segments:
                    raise RuntimeError("Empty audio")
                warmed_languages.add(language)
                if warming:
                    # Force MLX evaluation above; never play or write warmup audio.
                    client.sendall(b'{"status":"ok","warmed":true}\n'); return
                descriptor, out = tempfile.mkstemp(suffix=".wav", dir=audio_root)
                os.close(descriptor)
                write(out, np.concatenate(segments), rate, format="wav")
                client.sendall(json.dumps({"status": "ok", "audio_file": out}).encode() + b"\n")
                out = None  # client owns deletion after playback
        except Exception as error:
            print("Synthesis failure:", type(error).__name__, "file:", getattr(error, "filename", None), file=sys.stderr, flush=True)
            try:
                client.sendall(b'{"status":"error","message":"Local synthesis failed"}\n')
            except OSError:
                pass
        finally:
            if out and os.path.isfile(out):
                os.unlink(out)
            client.close(); last_use[0] = time.monotonic()

    def shutdown(_sig=None, _frame=None):
        listener.close(); sock_path.unlink(missing_ok=True); sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown); signal.signal(signal.SIGINT, shutdown)
    while True:
        if time.monotonic() - last_use[0] > 600 and not generation.locked():
            shutdown()
        try:
            client, _ = listener.accept()
            threading.Thread(target=handle, args=(client,), daemon=True).start()
        except socket.timeout:
            for old in audio_root.glob("*.wav"):
                if time.time() - old.stat().st_mtime > 3600:
                    old.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
