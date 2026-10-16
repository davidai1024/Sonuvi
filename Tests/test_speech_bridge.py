import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import wave
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'Resources/kokoro_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class SpeechTests(unittest.TestCase):
    def test_chunks_preserve_words_and_limit(self):
        text = ('Hello David. Let us practice English together. ' * 100).strip()
        output = list(bridge.chunks(text))
        self.assertEqual(' '.join(output).split(), text.split())
        self.assertTrue(all(len(x) <= 320 for x in output))
        self.assertGreater(len(output), 1)

    def test_owned_audio_cleaned_and_text_not_in_arguments(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root / 'ready.json').write_text(json.dumps({'python':sys.executable,'model':str(root/'model')}))
            (root/'Audio').mkdir()
            audio=root/'Audio/test.wav'
            with wave.open(str(audio), 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(b'\0\0' * 24000)
            class FakePlayer:
                def __init__(self, args, **kwargs):
                    self.args=args
                    self.assertion='private selected text' not in str(args)
                    if not self.assertion: raise AssertionError('Text leaked in process args')
                def wait(self): return 0
            def connect(*args,**kwargs): bridge.connection=type('C',(),{'close':lambda self: None})()
            with patch.object(sys,'argv',['bridge','--root',str(root),'--service',str(root/'service.py')]), patch.object(sys,'stdin',io.StringIO(json.dumps({'text':'private selected text','voice':'af_heart'}))), patch.object(bridge,'connect',connect), patch.object(bridge,'exchange',return_value={'status':'ok','audio_file':str(audio)}), patch.object(bridge.subprocess,'Popen',FakePlayer), contextlib.redirect_stdout(io.StringIO()) as output:
                bridge.main()
            self.assertEqual(json.loads(output.getvalue())['audio_seconds'], 1.0)
            self.assertFalse(audio.exists())

    def test_native_player_waits_for_ack_before_deleting_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); (root/'Audio').mkdir()
            (root/'ready.json').write_text(json.dumps({'python': sys.executable}))
            audio = root/'Audio/native.wav'
            with wave.open(str(audio), 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                wav.writeframes(b'\0\0' * 2400)
            class NativeInput(io.StringIO):
                def readline(self, *args):
                    if self.tell() > 0:
                        if not audio.exists(): raise AssertionError('Audio deleted before player acknowledgement')
                    return super().readline(*args)
            incoming = NativeInput(json.dumps({'text': 'Native audio test.'}) + '\n{"action":"continue"}\n')
            def connect(*args, **kwargs): bridge.connection = type('C', (), {'close': lambda self: None})()
            with patch.object(sys, 'argv', ['bridge', '--root', str(root), '--service', str(root/'service.py'), '--native-player']), patch.object(sys, 'stdin', incoming), patch.object(bridge, 'connect', connect), patch.object(bridge, 'exchange', return_value={'status': 'ok', 'audio_file': str(audio)}), patch.object(bridge.subprocess, 'Popen') as launch, contextlib.redirect_stdout(io.StringIO()) as output:
                bridge.main()
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(events[0], {'event': 'audio', 'path': str(audio)})
            self.assertEqual(events[-1]['audio_seconds'], .1)
            launch.assert_not_called(); self.assertFalse(audio.exists())

    def test_native_player_eof_cleans_unplayed_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); (root/'Audio').mkdir()
            (root/'ready.json').write_text(json.dumps({'python': sys.executable}))
            audio = root/'Audio/cancel.wav'
            with wave.open(str(audio), 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(b'\0\0'*24)
            def connect(*args, **kwargs): bridge.connection = type('C', (), {'close': lambda self: None})()
            bridge.player = None
            with patch.object(sys, 'argv', ['bridge', '--root', str(root), '--service', str(root/'service.py'), '--native-player']), patch.object(sys, 'stdin', io.StringIO('{"text":"Cancel test."}\n')), patch.object(bridge, 'connect', connect), patch.object(bridge, 'exchange', return_value={'status':'ok','audio_file':str(audio)}), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit): bridge.main()
            self.assertFalse(audio.exists()); bridge.owned_audio = None

    def test_engine_restarts_after_zero_exit_lock_race(self):
        with tempfile.TemporaryDirectory() as folder:
            attempts = {'count': 0}
            class FakeSocket:
                def settimeout(self, _): pass
                def connect(self, _):
                    attempts['count'] += 1
                    if attempts['count'] < 3: raise FileNotFoundError()
                def close(self): pass
            class ExitedDaemon:
                def poll(self): return 0
            with patch.object(bridge.socket, 'socket', return_value=FakeSocket()), patch.object(bridge.subprocess, 'Popen', return_value=ExitedDaemon()) as launch, patch.object(bridge.time, 'sleep'):
                bridge.connect(Path(folder) / 'tts.sock', ['local-service'], {})
            self.assertEqual(launch.call_count, 2)
            bridge.connection = None

    def test_stop_terminates_player_and_removes_owned_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            audio=Path(folder)/'audio.wav'; audio.write_bytes(b'fixture')
            state={'stopped':False}
            class FakePlayer:
                def poll(self): return None
                def terminate(self): state['stopped']=True
            bridge.player=FakePlayer(); bridge.connection=None; bridge.owned_audio=str(audio)
            with self.assertRaises(SystemExit): bridge.stop(None,None)
            self.assertTrue(state['stopped']); self.assertFalse(audio.exists())
            bridge.player=None; bridge.owned_audio=None

if __name__ == '__main__': unittest.main()
