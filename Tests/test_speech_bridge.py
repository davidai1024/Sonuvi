import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import wave
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'Resources/kokoro_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class SpeechTests(unittest.TestCase):
    def setUp(self):
        bridge.cancelled.clear()
        bridge.connection = None
        bridge.player = None
        bridge.cleanup_audio()

    def tearDown(self):
        bridge.cancel_work()

    def test_new_voice_service_accepts_current_protocol_without_restart(self):
        with patch.object(bridge, 'connect'), patch.object(bridge, 'exchange', return_value={'voice_protocol': 2}) as exchange:
            bridge.ensure_extended_voice_service(Path('/unused/socket'), [], {})
            exchange.assert_called_once_with({'action': 'capabilities'})

    def test_new_voice_restarts_old_engine_before_synthesis(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'socket'
            class Client:
                def shutdown(self, *args): pass
                def close(self): pass
            def connect(*args, **kwargs): bridge.connection = Client()
            with patch.object(bridge, 'connect', connect), patch.object(bridge, 'exchange', side_effect=[{'status': 'error'}, {'status': 'ok'}]) as exchange:
                bridge.ensure_extended_voice_service(path, [], {})
                self.assertEqual([x.args[0] for x in exchange.call_args_list], [{'action':'capabilities'}, {'action':'shutdown'}])


    def test_warmup_never_reads_input_or_starts_playback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root/'ready.json').write_text(json.dumps({'python':sys.executable,'model':str(root/'model')}))
            class ForbiddenInput:
                def read(self, *args): raise AssertionError("Warmup read user text")
                def readline(self, *args): raise AssertionError("Warmup read user text")
            def connect(*args, **kwargs):
                bridge.connection = type('C', (), {'close': lambda self: None})()
            with patch.object(sys, 'argv', ['bridge', '--root',str(root),'--service',str(root/'service.py'),'--warmup','--voice','bf_emma']), patch.object(sys,'stdin',ForbiddenInput()), patch.object(bridge,'ensure_extended_voice_service') as upgrade, patch.object(bridge,'connect',connect), patch.object(bridge,'exchange',return_value={'status':'ok'}) as exchange, patch.object(bridge.subprocess,'Popen') as launch:
                bridge.main()
                self.assertEqual(upgrade.call_args.kwargs, {'engine_protocol':3})
                exchange.assert_called_once_with({'action':'warmup','voice':'bf_emma'})
                launch.assert_not_called()
                self.assertIsNone(bridge.connection)
                self.assertFalse((root/'Audio').exists())

    def test_warmup_failure_can_be_retried_without_playback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root/'ready.json').write_text(json.dumps({'python':sys.executable,'model':str(root/'model')}))
            def connect(*args, **kwargs):
                bridge.connection = type('C', (), {'close': lambda self: None})()
            with patch.object(sys,'argv',['bridge','--root',str(root),'--service',str(root/'service.py'),'--warmup']), patch.object(bridge,'ensure_extended_voice_service'), patch.object(bridge,'connect',connect), patch.object(bridge,'exchange',return_value={'status':'error'}):
                with self.assertRaises(RuntimeError): bridge.main()
                self.assertIsNone(bridge.connection)

    def test_warmup_does_not_start_legacy_engine(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(sys,'argv',['bridge','--root',folder,'--service','unused','--warmup']), patch.object(bridge,'connect') as connect:
            # Legacy paths may be absent; warmup should simply skip them.
            bridge.main()
            connect.assert_not_called()

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

    def test_sentence_boundaries_precede_character_budget(self):
        sentence = 'A complete sentence should stay together.'
        output = list(bridge.chunks(' '.join([sentence] * 12), limit=90))
        self.assertEqual(output, [' '.join([sentence] * 2)] * 6)
        self.assertTrue(all(part.endswith('.') for part in output))

    def test_long_sentence_prefers_clause_boundary(self):
        text = 'We can prepare the next segment, while the current segment plays, and continue without waiting.'
        output = list(bridge.chunks(text, limit=65))
        self.assertEqual(' '.join(output), text)
        self.assertEqual(output[0], 'We can prepare the next segment, while the current segment plays,')

    def test_prefetch_ready_before_current_playback_ack_and_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); (root/'Audio').mkdir()
            (root/'ready.json').write_text(json.dumps({'python': sys.executable}))
            ready = [threading.Event() for _ in range(6)]
            generated = []
            def connect(*args, **kwargs):
                bridge.connection = type('C', (), {'close': lambda self: None})()
            def exchange(payload):
                index = len(generated)
                audio = root/'Audio'/f'{index}.wav'
                with wave.open(str(audio), 'wb') as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                    wav.writeframes(b'\0\0' * 2400)
                generated.append(audio); ready[index].set()
                return {'status': 'ok', 'audio_file': str(audio)}
            # Exactly four chunks of two complete sentences each.
            text = ('A sentence that is long enough to form part of a realistic English reading passage. ' * 8).strip()
            count = len(list(bridge.chunks(text)))
            acknowledgements = []
            class NativeInput(io.StringIO):
                def readline(inner, *args):
                    if inner.tell() > 0:
                        index = len(acknowledgements)
                        if index + 1 < count:
                            self.assertTrue(ready[index + 1].wait(3), 'Next chunk was not synthesized during playback')
                            self.assertEqual(len(generated), index + 2, 'More than one chunk prefetched')
                        self.assertTrue(generated[index].exists(), 'Current audio deleted before playback ended')
                        self.assertLessEqual(len(list((root/'Audio').glob('*.wav'))), 2)
                        acknowledgements.append(index)
                    return super().readline(*args)
            incoming = NativeInput(json.dumps({'text': text}) + '\n' + '{"action":"continue"}\n' * count)
            with patch.object(sys, 'argv', ['bridge', '--root', str(root), '--service', str(root/'service.py'), '--native-player']), patch.object(sys, 'stdin', incoming), patch.object(bridge, 'connect', connect), patch.object(bridge, 'exchange', exchange), contextlib.redirect_stdout(io.StringIO()) as output:
                bridge.main()
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(len([e for e in events if e.get('event') == 'audio']), count)
            self.assertAlmostEqual(events[-1]['audio_seconds'], count * .1)
            self.assertEqual(len(acknowledgements), count)
            self.assertEqual(list((root/'Audio').glob('*.wav')), [])

    def test_cancel_interrupts_inflight_prefetch_and_cleans_its_late_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); (root/'Audio').mkdir()
            (root/'ready.json').write_text(json.dumps({'python': sys.executable}))
            entered = threading.Event(); disconnected = threading.Event()
            generated = []
            class Client:
                def shutdown(self, _): disconnected.set()
                def close(self): pass
            def connect(*args, **kwargs):
                bridge.connection = Client()
            def exchange(payload):
                index = len(generated)
                if index:
                    disconnected.clear(); entered.set()
                    self.assertTrue(disconnected.wait(3), 'Cancel did not interrupt synthesis connection')
                audio = root/'Audio'/f'{index}.wav'
                with wave.open(str(audio), 'wb') as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                    wav.writeframes(b'\0\0' * 24)
                generated.append(audio)
                return {'status': 'ok', 'audio_file': str(audio)}
            class NativeInput(io.StringIO):
                def readline(inner, *args):
                    if inner.tell() > 0:
                        self.assertTrue(entered.wait(3))
                        return ''
                    return super().readline(*args)
            incoming = NativeInput(json.dumps({'text': 'A full English sentence with enough detail to need multiple chunks. ' * 12}) + '\n')
            with patch.object(sys, 'argv', ['bridge', '--root', str(root), '--service', str(root/'service.py'), '--native-player']), patch.object(sys, 'stdin', incoming), patch.object(bridge, 'connect', connect), patch.object(bridge, 'exchange', exchange), contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaises(SystemExit): bridge.main()
            self.assertEqual(len(generated), 2)
            self.assertEqual(len(output.getvalue().splitlines()), 1, 'Canceled audio must not be sent to player')
            self.assertEqual(list((root/'Audio').glob('*.wav')), [])

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
