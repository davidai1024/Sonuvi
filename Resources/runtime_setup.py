#!/usr/bin/env python3
"""Prepare an independently owned Kokoro runtime. GPL-3.0."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runtime_compat import validate_tree

RUNTIME_REVISION = "mlx-0.32.4-macos14-v1"
# Pin the macOS 14 artifacts explicitly: the same MLX version also ships
# macOS 26 wheels, which a build on a newer Mac otherwise prefers.
MLX_WHEELS = [
    "https://files.pythonhosted.org/packages/69/b0/e726ce51e1b445e4ed08c2d0e036a01c7532f4d1a856328da546a6f883bd/mlx-0.32.4-cp312-cp312-macosx_14_0_arm64.whl#sha256=ff1d7be54758ea3a875b8fe54eff13bed17ad9566505e301f5d7851bf869680f",
    "https://files.pythonhosted.org/packages/77/24/7e5b7ed5d28abacab4577c7a8dd1fca6e9058504f5f95ae4333c09420e2e/mlx_metal-0.32.4-py3-none-macosx_14_0_arm64.whl#sha256=8019b2db622599267d66cc168b2f0dbf5af929790a6c3b3913e00eabc42a7947",
]

MODEL_ID = "mlx-community/Kokoro-82M-bf16"
MODEL_REVISION = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
child = None


def stop(_signal, _frame):
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
    raise SystemExit(130)


def emit(stage, message):
    print(json.dumps({"stage": stage, "message": message}, ensure_ascii=False), flush=True)


def run(command, env=None):
    global child
    # Installer logs stay in the runtime's own directory, never include text/keys.
    proc = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    child = proc
    for line in proc.stdout:
        if line.strip():
            emit("progress", line.strip()[-240:])
    if proc.wait():
        raise RuntimeError("安装步骤失败，请检查网络后重试")
    child = None


def clone_tree(source, destination):
    global child
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # APFS clones are independent files, not hardlinks to Speak11's environment.
    child = subprocess.Popen(["/bin/cp", "-cR", str(source), str(destination)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    result = child.wait(); child = None
    if result:
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination, symlinks=False)


def verify(python, root):
    validate_tree(python.parent.parent, '14.0')
    code = "import sys,mlx.core,misaki,soundfile,spacy; from mlx_audio.tts.utils import load_model; print(sys.prefix)"
    prefix = subprocess.check_output([str(python), "-I", "-c", code], text=True).strip()
    if not Path(prefix).resolve().is_relative_to(root.resolve()):
        raise RuntimeError("运行环境仍引用外部 Python，导入未完成")


def main():
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--uv", required=True, type=Path)
    parser.add_argument("--mode", choices=["import", "download", "bundled"], required=True)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    with (root / "setup.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise RuntimeError("已有模型安装正在进行，请稍后再试")
        if shutil.disk_usage(root).free < 2_500_000_000:
            raise RuntimeError("可用磁盘空间不足，请至少预留 2.5GB")
        ready = root / "ready.json"
        stage = root / ("installation-" + str(time.time_ns()) + ".partial")
        stage.mkdir()
        env = os.environ.copy()
        env["UV_PYTHON_INSTALL_DIR"] = str(root / "Python")
        env["UV_CACHE_DIR"] = str(root / "Cache/uv")
        env["HF_HOME"] = str(root / "Cache/huggingface")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if args.mode == "bundled":
            if args.bundle is None:
                raise RuntimeError("未找到内置朗读环境")
            bundle = args.bundle.resolve()
            manifest = json.loads((bundle / "manifest.json").read_text())
            if manifest.get("format") != 1 or manifest.get("architecture") != "arm64":
                raise RuntimeError("内置朗读环境格式不支持")
            emit("runtime", "正在准备内置朗读环境，无需联网…")
            clone_tree(bundle / "runtime", stage / "runtime")
            clone_tree(bundle / "model", stage / "model")
            python = stage / "runtime/bin/python3"
            # Full packages contain a standalone CPython distribution, never
            # a venv with links back to the build machine.
            if (stage / "runtime/pyvenv.cfg").exists():
                raise RuntimeError("内置 Python 必须是可迁移的独立环境")
            for link in stage.rglob("*"):
                if link.is_symlink() and not link.resolve().is_relative_to(stage):
                    raise RuntimeError("内置环境含外部链接，无法在本机使用")
        elif args.mode == "import":
            seed = Path.home() / ".local/share/speak11/venv"
            seed_python = seed / "bin/python3"
            if not seed_python.exists():
                raise RuntimeError("未检测到已安装的 Speak11，可选择联网安装")
            info = json.loads(subprocess.check_output([str(seed_python), "-c", "import sys,json;print(json.dumps({'base':sys.base_prefix,'version':f'{sys.version_info.major}.{sys.version_info.minor}'}))"], text=True))
            version = info["version"]
            emit("runtime", "正在导入独立 Python 环境…")
            runtime = stage / "runtime"
            clone_tree(Path(info["base"]).resolve(), runtime)
            site_source = seed / "lib" / ("python" + version) / "site-packages"
            site_target = runtime / "lib" / ("python" + version) / "site-packages"
            clone_tree(site_source, site_target)
            # Verify no absolute symlink can keep a dependency on the seed.
            for link in runtime.rglob("*"):
                if link.is_symlink() and os.path.isabs(os.readlink(link)):
                    target = link.resolve()
                    if target.is_file():
                        link.unlink(); shutil.copy2(target, link)
                    else:
                        raise RuntimeError("运行环境含外部目录链接，请改用联网安装")
            python = runtime / "bin/python3"
            emit("model", "正在导入 Kokoro 模型和英文音色…")
            snapshot = Path.home() / ".cache/huggingface/hub/models--mlx-community--Kokoro-82M-bf16/snapshots" / MODEL_REVISION
            if not snapshot.exists():
                raise RuntimeError("没有找到完整 Kokoro 模型，可选择联网安装")
            clone_tree(snapshot, stage / "model")
            # Materialize all model symlinks so the original cache may be removed.
            for link in (stage / "model").rglob("*"):
                if link.is_symlink():
                    relative = link.relative_to(stage / "model")
                    source = (snapshot / relative).resolve()
                    link.unlink()
                    if source.is_file():
                        shutil.copy2(source, link)
                    else:
                        raise RuntimeError("模型链接不完整，请改用联网安装")
        else:
            emit("runtime", "正在下载独立 Python…")
            run([str(args.uv), "python", "install", "3.12"], env)
            run([str(args.uv), "venv", "--managed-python", "--python", "3.12", str(stage / "runtime")], env)
            python = stage / "runtime/bin/python3"
            emit("dependencies", "正在安装本地语音依赖…")
            run([str(args.uv), "pip", "install", "--python", str(python), "mlx-audio==0.5.9", *MLX_WHEELS, "misaki==0.8.4", "spacy==3.8.16", "soundfile==0.14.0", "phonemizer-fork", "espeakng_loader==0.2.4", "num2words", "loguru", "pysbd", "ftfy"], env)
            run([str(args.uv), "pip", "install", "--python", str(python), "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"], env)
            emit("model", "正在下载 Kokoro 模型，约 350MB…")
            run([str(python), "-c", "from huggingface_hub import snapshot_download;import sys; snapshot_download(sys.argv[1],revision=sys.argv[2],local_dir=sys.argv[3])", MODEL_ID, MODEL_REVISION, str(stage / "model")], env)
        emit("verify", "正在检查环境与模型文件…")
        verify(python, root)
        pronunciation = next((stage / "runtime/lib").glob("python*/site-packages/espeakng_loader/espeak-ng-data"), None)
        if pronunciation is not None:
            clone_tree(pronunciation, root / "espeak-ng-data")
        if not (stage / "model/config.json").is_file() or not (stage / "model/kokoro-v1_0.safetensors").is_file():
            raise RuntimeError("模型文件不完整，请重新安装")
        # Each installation has a permanent unique path: no venv relocation.
        # The ready marker is atomic; previous working installations stay intact.
        # Move only imported standalone distributions, never a generated venv.
        if args.mode in ("import", "bundled"):
            final = root / ("install-" + str(time.time_ns()))
            stage.rename(final)
        else:
            final = stage
        result = {"version": 1, "python": str(final / "runtime/bin/python3"), "model": str(final / "model"), "source": args.mode, "created": time.time(), "runtimeRevision": RUNTIME_REVISION}
        tmp = root / "ready.partial.json"
        tmp.write_text(json.dumps(result), encoding="utf-8")
        # A live service must release the old files before a marker switch.
        # On permission/timeout errors retain the previous working environment.
        if (root / "tts.sock").exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(2); connection.connect(str(root / "tts.sock"))
                    connection.sendall(b'{"action":"shutdown"}\n')
                    response = json.loads(connection.recv(4096))
                    if response.get("status") != "ok":
                        raise RuntimeError("旧朗读引擎未能停止，请退出应用后重试")
                for _ in range(40):
                    if not (root / "tts.sock").exists():
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError("旧朗读引擎仍在退出，请稍后重试")
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            except OSError:
                raise RuntimeError("无法停止旧朗读引擎，已保留原环境。请退出应用后重试")
        os.replace(tmp, ready)
        # Only generated, superseded installation folders are reclaimed.
        # Existing working files are untouched until the atomic marker switch.
        for previous in root.iterdir():
            if previous.is_dir() and previous != final and (previous.name.startswith("install-") or (previous.name.startswith("installation-") and previous.name.endswith(".partial"))):
                shutil.rmtree(previous, ignore_errors=True)
        emit("done", "内置朗读环境已就绪" if args.mode == "bundled" else "独立环境已就绪，不再依赖 Speak11")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("error", str(error))
        sys.exit(1)
