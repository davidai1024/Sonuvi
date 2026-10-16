#!/usr/bin/env python3
"""Local-only Kokoro speech client. GPL-3.0. No selected text in arguments/logs."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import wave

player = None
connection = None
owned_audio = None


def stop(_signum, _frame):
    if connection is not None:
        connection.close()
    if player is not None and player.poll() is None:
        player.terminate()
    if owned_audio:
        Path(owned_audio).unlink(missing_ok=True)
    raise SystemExit(0)


def chunks(text, limit=320):
    pieces = re.split(r'(?<=[.!?])\s+|\n+', text.strip())
    buffer = ''
    for piece in pieces:
        words = piece.split()
        for word in words:
            if len(buffer) + len(word) + 1 > limit and buffer:
                yield buffer
                buffer = ''
            buffer += (' ' if buffer else '') + word
    if buffer:
        yield buffer


def connect(path, service, environment, shutdown=False):
    global connection
    launched = False
    daemon = None
    deadline = time.monotonic() + 50
    while True:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(90)
        try:
            connection.connect(str(path))
            return
        except (FileNotFoundError, ConnectionRefusedError):
            connection.close()
            connection = None
            if shutdown:
                return
            if not launched:
                log_path = Path(path).parent / 'engine-errors.log'
                with log_path.open('a') as error_log:
                    daemon = subprocess.Popen(service, env=environment, stdin=subprocess.DEVNULL,
                                              stdout=subprocess.DEVNULL, stderr=error_log,
                                              start_new_session=True)
                launched = True
            if daemon is not None and daemon.poll() == 0:
                # The previous engine may still be releasing its lock after
                # shutdown. A zero-exit duplicate must not consume all retries.
                launched = False
            if daemon is not None and daemon.poll() not in (None, 0):
                raise RuntimeError('本地引擎启动失败，请在设置中重新导入或下载模型')
            if time.monotonic() > deadline:
                raise RuntimeError('Kokoro 启动超时，请在设置中修复或重新导入模型')
            time.sleep(0.2)


def exchange(payload):
    connection.sendall(json.dumps(payload).encode() + b'\n')
    data = bytearray()
    while b'\n' not in data:
        block = connection.recv(4096)
        if not block:
            break
        data.extend(block)
        if len(data) > 1_000_000:
            raise RuntimeError('Kokoro 返回异常')
    return json.loads(data)


def main():
    global connection, player, owned_audio
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--service', type=Path, required=True)
    parser.add_argument('--shutdown', action='store_true')
    parser.add_argument('--native-player', action='store_true')
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    root = args.root.resolve()
    independent = (root / 'ready.json').is_file()
    env = os.environ.copy()
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    if independent:
        info = json.loads((root / 'ready.json').read_text())
        path = root / 'tts.sock'
        service = [info['python'], str(args.service), '--root', str(root)]
        env['HF_HOME'] = str(root / 'Cache/huggingface')
        env['HF_HUB_OFFLINE'] = '1'
    else:
        if args.shutdown:
            return
        python = Path.home() / '.local/share/speak11/venv/bin/python3'
        legacy = Path.home() / '.local/bin/tts_server.py'
        if not python.exists() or not legacy.exists():
            raise RuntimeError('请先在设置中下载或导入本地模型')
        path = Path.home() / '.local/share/speak11/tts.sock'
        service = [str(python), str(legacy)]
    if args.shutdown:
        connect(path, service, env, shutdown=True)
        if connection is not None:
            exchange({'action': 'shutdown'}); connection.close()
        return
    request = json.loads(sys.stdin.readline()) if args.native_player else json.load(sys.stdin)
    text = request.get('text')
    if not isinstance(text, str) or not text.strip() or len(text) > 6000:
        raise ValueError('请选择 6000 字以内的英文')
    voice = request.get('voice', 'af_heart')
    if voice not in ('af_heart','af_bella','bf_lily','bm_george','am_michael'):
        voice = 'af_heart'
    speed = min(2.0, max(0.5, float(request.get('speed', 1))))
    audio_seconds = 0.0
    for part in chunks(text):
        connect(path, service, env)
        response = exchange({'text':part,'voice':voice,'speed':speed,'lang_code':'b' if voice.startswith('b') else 'a'})
        connection.close(); connection = None
        audio = response.get('audio_file')
        if response.get('status') != 'ok' or not audio or not Path(audio).is_file():
            raise RuntimeError('Kokoro 合成失败，请在设置中修复模型')
        candidate = Path(audio).resolve()
        if independent and candidate.is_relative_to(root / 'Audio'):
            owned_audio = str(candidate)
        with wave.open(audio, "rb") as wav:
            part_seconds = wav.getnframes() / wav.getframerate()
        if args.native_player:
            # The native player acknowledges only after actual playback finishes.
            # Keep the file alive until then; SIGTERM still removes it on cancel.
            print(json.dumps({'event': 'audio', 'path': str(candidate)}), flush=True)
            acknowledgement = sys.stdin.readline()
            if not acknowledgement or json.loads(acknowledgement).get('action') != 'continue':
                stop(None, None)
            status = 0
        else:
            player = subprocess.Popen(['/usr/bin/afplay', audio], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            status = player.wait()
        if owned_audio:
            Path(owned_audio).unlink(missing_ok=True); owned_audio = None
        if status:
            raise RuntimeError('音频播放失败')
        audio_seconds += part_seconds
    print(json.dumps({'status':'ok', 'audio_seconds':audio_seconds}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error) if isinstance(error,(RuntimeError,ValueError)) else '本地朗读失败，请在设置中检查模型'
        print(json.dumps({'status':'error','message':message},ensure_ascii=False))
        sys.exit(1)
