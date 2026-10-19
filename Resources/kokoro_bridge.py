#!/usr/bin/env python3
"""Local-only Kokoro speech client. GPL-3.0. No selected text in arguments/logs."""
import argparse
from concurrent.futures import CancelledError, ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import wave

player = None
connection = None
owned_audio = None
owned_audios = set()
audio_lock = threading.RLock()
cancelled = threading.Event()


def close_connection():
    global connection
    client = connection
    connection = None
    if client is not None:
        try:
            client.shutdown(socket.SHUT_RDWR)
        except (OSError, AttributeError):
            pass
        client.close()


def cleanup_audio():
    global owned_audio
    with audio_lock:
        paths = set(owned_audios)
        if owned_audio:
            paths.add(owned_audio)
        owned_audios.clear()
        owned_audio = None
    for path in paths:
        Path(path).unlink(missing_ok=True)


def cancel_work():
    cancelled.set()
    close_connection()
    if player is not None and player.poll() is None:
        player.terminate()
    cleanup_audio()


def stop(_signum, _frame):
    cancel_work()
    raise SystemExit(0)


def pack_units(units, limit):
    buffer = ''
    for unit in units:
        unit = ' '.join(unit.split())
        if not unit:
            continue
        if buffer and len(buffer) + len(unit) + 1 > limit:
            yield buffer
            buffer = ''
        # A single clause can exceed the budget. Split only at word boundaries.
        if len(unit) > limit:
            words = unit.split()
            for word in words:
                if buffer and len(buffer) + len(word) + 1 > limit:
                    yield buffer
                    buffer = ''
                buffer += (' ' if buffer else '') + word
        else:
            buffer += (' ' if buffer else '') + unit
    if buffer:
        yield buffer


def chunks(text, limit=320):
    # Pack complete sentences first; only oversized sentences fall back to
    # clause punctuation, and then to word boundaries for oversized clauses.
    sentences = re.split(r'(?<=[.!?])\s+|(?<=[.!?]["”’])\s+|\n+', text.strip())
    units = []
    for sentence in sentences:
        sentence = ' '.join(sentence.split())
        if len(sentence) <= limit:
            units.append(sentence)
        else:
            clauses = re.split(r'(?<=[,;:—–])\s+', sentence)
            units.extend(pack_units(clauses, limit))
    yield from pack_units(units, limit)


def connect(path, service, environment, shutdown=False):
    global connection
    launched = False
    daemon = None
    deadline = time.monotonic() + 50
    while True:
        if cancelled.is_set():
            raise CancelledError()
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
    client = connection
    client.sendall(json.dumps(payload).encode() + b'\n')
    data = bytearray()
    while b'\n' not in data:
        block = client.recv(4096)
        if not block:
            break
        data.extend(block)
        if len(data) > 1_000_000:
            raise RuntimeError('Kokoro 返回异常')
    return json.loads(data)


def ensure_extended_voice_service(path, service, environment, engine_protocol=0):
    """Upgrade a running five-voice engine before requesting a new voice."""
    try:
        connect(path, service, environment)
        reply = exchange({'action': 'capabilities'})
    finally:
        close_connection()
    if reply.get('voice_protocol', 0) >= 2 and reply.get('engine_protocol', 0) >= engine_protocol:
        return
    try:
        connect(path, service, environment, shutdown=True)
        if connection is not None:
            exchange({'action': 'shutdown'})
    finally:
        close_connection()
    deadline = time.monotonic() + 3
    while path.exists():
        if cancelled.is_set():
            raise CancelledError()
        if time.monotonic() > deadline:
            raise RuntimeError('旧朗读引擎仍在退出，请稍后重试')
        time.sleep(0.05)


def synthesize(part, path, service, environment, independent, root, voice, speed):
    if cancelled.is_set():
        raise CancelledError()
    try:
        connect(path, service, environment)
        response = exchange({'text': part, 'voice': voice, 'speed': speed,
                             'lang_code': 'b' if voice.startswith('b') else 'a'})
    finally:
        close_connection()
    audio = response.get('audio_file')
    if response.get('status') != 'ok' or not audio or not Path(audio).is_file():
        raise RuntimeError('Kokoro 合成失败，请在设置中修复模型')
    candidate = Path(audio).resolve()
    owned = independent and candidate.is_relative_to(root / 'Audio')
    with audio_lock:
        if owned:
            owned_audios.add(str(candidate))
        if cancelled.is_set():
            if owned:
                candidate.unlink(missing_ok=True)
                owned_audios.discard(str(candidate))
            raise CancelledError()
    with wave.open(str(candidate), 'rb') as wav:
        seconds = wav.getnframes() / wav.getframerate()
    return candidate, seconds, owned


def main():
    global connection, player, owned_audio
    cancelled.clear()
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--service', type=Path, required=True)
    parser.add_argument('--shutdown', action='store_true')
    parser.add_argument('--native-player', action='store_true')
    parser.add_argument('--warmup', action='store_true')
    parser.add_argument('--voice', default='af_heart')
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
        service = [info['python'], '-I', str(args.service), '--root', str(root)]
        env['HF_HOME'] = str(root / 'Cache/huggingface')
        env['HF_HUB_OFFLINE'] = '1'
    else:
        if args.shutdown or args.warmup:
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
    if args.warmup:
        # No clipboard, selected text, playback or audio file involved.
        if not independent:
            return
        voice = args.voice if re.fullmatch(r'[ab][fm]_[a-z]+', args.voice) else 'af_heart'
        ensure_extended_voice_service(path, service, env, engine_protocol=3)
        try:
            connect(path, service, env)
            reply = exchange({'action': 'warmup', 'voice': voice})
            if reply.get('status') != 'ok':
                raise RuntimeError('本地引擎预热未完成')
        finally:
            close_connection()
        return
    request = json.loads(sys.stdin.readline()) if args.native_player else json.load(sys.stdin)
    text = request.get('text')
    if not isinstance(text, str) or not text.strip() or len(text) > 6000:
        raise ValueError('请选择 6000 字以内的英文')
    voice = request.get('voice', 'af_heart')
    if not isinstance(voice, str) or not re.fullmatch(r'[ab][fm]_[a-z]+', voice):
        voice = 'af_heart'
    if independent and voice not in ('af_heart', 'af_bella', 'bf_lily', 'bm_george', 'am_michael'):
        model = Path(info['model'])
        if not (model / 'voices' / (voice + '.safetensors')).is_file():
            raise RuntimeError('所选音色尚未安装，请在模型设置中恢复内置模型')
        ensure_extended_voice_service(path, service, env)
    speed = min(2.0, max(0.5, float(request.get('speed', 1))))
    audio_seconds = 0.0
    parts = iter(chunks(text))
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='sonuvi-prefetch')
    def prepare(part):
        return synthesize(part, path, service, env, independent, root, voice, speed)
    try:
        current = prepare(next(parts))
        while current is not None:
            candidate, part_seconds, owned = current
            owned_audio = str(candidate) if owned else None
            if args.native_player:
                print(json.dumps({'event': 'audio', 'path': str(candidate)}), flush=True)
            else:
                player = subprocess.Popen(['/usr/bin/afplay', str(candidate)], stdin=subprocess.DEVNULL,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # Only one chunk ahead: synthesis overlaps playback, with a bounded
            # two-file working set (current + next) even for long selections.
            following = next(parts, None)
            future = executor.submit(prepare, following) if following is not None else None
            if args.native_player:
                acknowledgement = sys.stdin.readline()
                if not acknowledgement or json.loads(acknowledgement).get('action') != 'continue':
                    stop(None, None)
                status = 0
            else:
                status = player.wait()
                player = None
            if owned:
                with audio_lock:
                    candidate.unlink(missing_ok=True)
                    owned_audios.discard(str(candidate))
                    owned_audio = None
            if status:
                raise RuntimeError('音频播放失败')
            audio_seconds += part_seconds
            # A ready chunk can play immediately after the ACK. A synthesis
            # failure is surfaced after the current chunk has finished.
            current = future.result() if future is not None else None
    finally:
        cancel_work()
        executor.shutdown(wait=True, cancel_futures=True)
        cleanup_audio()
    print(json.dumps({'status':'ok', 'audio_seconds':audio_seconds}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error) if isinstance(error,(RuntimeError,ValueError)) else '本地朗读失败，请在设置中检查模型'
        print(json.dumps({'status':'error','message':message},ensure_ascii=False))
        sys.exit(1)
