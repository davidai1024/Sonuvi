"""Opt-in local performance test. Synthetic text only; never plays audio."""
import argparse
import json
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    project = Path(__file__).resolve().parents[1]
    python = bundle / "runtime/bin/python3"
    rows = []
    with tempfile.TemporaryDirectory(prefix="sonuvi-perf-") as directory:
        root = Path(directory)
        (root / "ready.json").write_text(json.dumps({"python":str(python), "model":str(bundle/"model")}))
        data = next((bundle/"runtime/lib").glob("python*/site-packages/espeakng_loader/espeak-ng-data"))
        (root/"espeak-ng-data").symlink_to(data, target_is_directory=True)
        def command(resources):
            return [str(python), "-I", str(resources/"kokoro_bridge.py"), "--root",str(root), "--service",str(resources/"kokoro_service.py")]
        def shutdown(resources):
            subprocess.run(command(resources)+["--shutdown"], capture_output=True, timeout=15)
            until = time.monotonic()+5
            while (root/"tts.sock").exists() and time.monotonic()<until:
                time.sleep(.05)
        def speech(resources, label, voice="af_heart"):
            start = time.monotonic()
            child = subprocess.Popen(command(resources)+["--native-player"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                child.stdin.write(json.dumps({"text":"A quiet reading tool lets you stay with the meaning of a passage. Your local voice should be ready when you need it.", "voice":voice})+"\n")
                child.stdin.flush()
                selector = selectors.DefaultSelector(); selector.register(child.stdout, selectors.EVENT_READ)
                if not selector.select(120): raise TimeoutError("First audio timed out")
                event = json.loads(child.stdout.readline())
                if event.get("event") != "audio": raise RuntimeError(event)
                elapsed = time.monotonic()-start
                child.stdin.write('{"action":"continue"}\n'); child.stdin.flush()
                output, error = child.communicate(timeout=30)
                if child.returncode: raise RuntimeError(error or output)
                selector.close()
                row = {"case":label, "first_audio_seconds":round(elapsed,3)}
                rows.append(row); print(json.dumps(row),flush=True)
            finally:
                if child.poll() is None: child.terminate(); child.wait(timeout=10)
        baseline = args.baseline.resolve()
        current = project/"Resources"
        try:
            speech(baseline, "0.4.7_cold")
            shutdown(baseline)
            start = time.monotonic()
            subprocess.run(command(current)+["--warmup","--voice","af_heart"],check=True,capture_output=True,timeout=150)
            print(json.dumps({"case":"background_warmup","seconds":round(time.monotonic()-start,3)}),flush=True)
            assert not list((root/"Audio").glob("*.wav")), "Warmup left audio on disk"
            speech(current,"0.4.8_after_warmup")
            start=time.monotonic()
            subprocess.run(command(current)+["--warmup","--voice","af_heart"],check=True,capture_output=True,timeout=30)
            print(json.dumps({"case":"keepalive","seconds":round(time.monotonic()-start,3)}),flush=True)
            speech(current,"0.4.8_repeat")
            subprocess.run(command(current)+["--warmup","--voice","bf_emma"],check=True,capture_output=True,timeout=60)
            speech(current,"0.4.8_british_after_warmup","bf_emma")
            assert not list((root/"Audio").glob("*.wav")), "Playback left temporary audio"
        finally:
            shutdown(current)
    print("PASS: background warmup is silent, reusable, and leaves no audio files",flush=True)

if __name__=="__main__": main()
