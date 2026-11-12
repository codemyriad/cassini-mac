#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the local render CLI with an inert launcher and owned PID fixtures."""
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('render-local-ux.py')
BOARDS = ('meeting', 'recording', 'received', 'export', 'search',
          'settings-recording', 'settings-transcription')

LAUNCHER = r'''
import base64
import json
import struct
import sys
import zlib
from pathlib import Path

mode, *arguments = sys.argv[1:]
def value(flag):
    return arguments[arguments.index(flag) + 1]

assert '-n' in arguments
Path(value('--stderr')).write_text('Private renderer diagnostic')
# Without -W, the fixture is still running and has produced no report.
if '-W' not in arguments or mode == 'missing':
    sys.exit(0)
if mode == 'invalid':
    Path(value('--stdout')).write_text('{')
    sys.exit(0)

board = value('-CassiniScreenshot')
width, height = (700, 500) if board.startswith('settings-') else (1120, 720)
if mode == 'dimensions':
    width -= 1

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes((1 + width * 4) * height)))
       + chunk(b'IEND', b''))
payload = base64.b64encode(png).decode() if mode != 'base64' else '!'
Path(value('--stdout')).write_text(json.dumps({
    'board': 'wrong' if mode == 'board' else board,
    'pngBase64': payload,
}))
'''


class RenderLocalUX(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cassini-render-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / ('Private fixture path ' * 8) / 'Cassini.app'
        for folder in ('main', 'received-only'):
            (self.app / 'Contents/Resources/Fixtures/Library' / folder).mkdir(parents=True)
        self.launcher = self.root / 'open-fixture.py'
        self.launcher.write_text(LAUNCHER)
        self.output = self.root / 'view.png'
        self.mode = 'valid'
        self.arguments = []
        self.real_run = subprocess.run

    def launch(self, command, **options):
        self.assertEqual(command[0], 'open')
        self.assertEqual(options['timeout'], 35)
        self.arguments = command
        diagnostic = Path(command[command.index('--stderr') + 1])
        if self.mode in ('timeout', 'exit', 'interrupt'):
            diagnostic.write_text('Private fixture failure')
            if self.mode == 'timeout':
                raise subprocess.TimeoutExpired(command, 35, stderr=b'Launch timeout detail')
            if self.mode == 'exit':
                raise subprocess.CalledProcessError(1, command, stderr=b'LaunchServices detail')
            raise KeyboardInterrupt
        return self.real_run([sys.executable, str(self.launcher), self.mode, *command[1:]], **options)

    def process_rows(self, command, **options):
        self.assertEqual(command[0], 'ps')
        self.assertEqual(options['stdin'], subprocess.DEVNULL)
        self.assertEqual(options['stderr'], subprocess.DEVNULL)
        self.assertNotIn('COLUMNS', options['env'])
        board = self.arguments[self.arguments.index('-CassiniScreenshot') + 1]
        nonce = self.arguments[self.arguments.index('-CassiniRenderID') + 1]
        prefix = f'{self.app.resolve()}/Contents/MacOS/Cassini -CassiniScreenshot {board} '
        rows = [
            '99000',
            f'99001 {prefix}-CassiniRenderID {nonce}',
            f'99002 {prefix}-CassiniRenderID 00000000-0000-4000-8000-000000000001',
            f'99003 {prefix}-CassiniRenderID {nonce}suffix',
            f'99004 /other/Cassini -CassiniScreenshot {board} -CassiniRenderID {nonce}',
            f'99005 {prefix}-CassiniRenderID another-render -CassiniListeningSpeaker -CassiniRenderID {nonce}',
        ]
        return '\n'.join(rows if '-ww' in command else [row[:79] for row in rows])

    def render(self, board='meeting', extra=(), error=None):
        argv = [str(SCRIPT), str(self.app), board, '--output', str(self.output), *extra]
        with patch.object(sys, 'argv', argv), patch.dict(os.environ, {
            'CASSINI_LOCAL_WORKFLOW_TESTS': '1', 'COLUMNS': '80',
        }), patch('subprocess.run', side_effect=self.launch), patch(
            'subprocess.check_output', side_effect=self.process_rows
        ), patch('os.kill') as terminate, patch('builtins.print'):
            if error is None:
                runpy.run_path(str(SCRIPT), run_name='__main__')
            else:
                with self.assertRaises(error) as failure:
                    runpy.run_path(str(SCRIPT), run_name='__main__')
            terminate.assert_called_once_with(99001, signal.SIGTERM)
        if error is None:
            self.assertTrue(self.output.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
            self.output.unlink()
            return None
        self.assertFalse(self.output.exists())
        return str(failure.exception)

    def test_reports_written_at_producer_exit(self):
        for board in BOARDS:
            with self.subTest(board=board):
                self.render(board)
                fixture = Path(self.arguments[self.arguments.index('-CassiniFixture') + 1])
                self.assertEqual(fixture.name, 'received-only' if board == 'received' else 'main')
                if board.startswith('settings-'):
                    self.assertIn('-CassiniSettingsID', self.arguments)

    def test_invalid_reports_are_rejected(self):
        for mode, error in (('missing', RuntimeError), ('invalid', RuntimeError),
                            ('board', AssertionError), ('dimensions', AssertionError),
                            ('base64', ValueError)):
            with self.subTest(mode=mode):
                self.mode = mode
                message = self.render(error=error)
                if mode in ('missing', 'invalid'):
                    self.assertIn('Private renderer diagnostic', message)

    def test_listening_and_speaker_reach_fixture(self):
        self.render(extra=('--listening', 'playing', '--speaker', 'Speaker 1'))
        self.assertEqual(self.arguments[self.arguments.index('-CassiniListeningPreview') + 1], 'playing')
        self.assertEqual(self.arguments[self.arguments.index('-CassiniListeningSpeaker') + 1], 'Speaker 1')
        self.assertEqual(self.arguments[self.arguments.index('-AppleInterfaceStyle') + 1], 'Light')
        self.assertNotIn('-CassiniScreenshotScheme', self.arguments)
        self.assertNotIn('-AppleAccentColor', self.arguments)

    def test_accent_is_unpinned_by_default_and_configurable_for_probes(self):
        self.render()
        self.assertNotIn('-AppleAccentColor', self.arguments)
        self.render(extra=('--accent', '1'))
        self.assertEqual(self.arguments[self.arguments.index('-AppleAccentColor') + 1], '1')
        with patch.dict(os.environ, {'CASSINI_SCREENSHOT_ACCENT': '5'}):
            self.render()
        self.assertEqual(self.arguments[self.arguments.index('-AppleAccentColor') + 1], '5')

    def test_dark_scheme_flag_and_environment_reach_fixture(self):
        self.render(extra=('--scheme', 'dark'))
        self.assertEqual(self.arguments[self.arguments.index('-AppleInterfaceStyle') + 1], 'Dark')
        self.assertEqual(self.arguments[self.arguments.index('-CassiniScreenshotScheme') + 1], 'dark')
        with patch.dict(os.environ, {'CASSINI_SCREENSHOT_SCHEME': 'dark'}):
            self.render()
        self.assertEqual(self.arguments[self.arguments.index('-AppleInterfaceStyle') + 1], 'Dark')
        self.assertEqual(self.arguments[self.arguments.index('-CassiniScreenshotScheme') + 1], 'dark')

    def test_launch_errors_keep_both_diagnostic_streams(self):
        for mode, message in (('timeout', 'Launch timeout detail'), ('exit', 'LaunchServices detail')):
            with self.subTest(mode=mode):
                self.mode = mode
                diagnostics = self.render(error=RuntimeError)
                self.assertIn(message, diagnostics)
                self.assertIn('Private fixture failure', diagnostics)

    def test_interrupt_cleans_only_owned_process_on_narrow_terminal(self):
        self.mode = 'interrupt'
        self.render(error=KeyboardInterrupt)


if __name__ == '__main__':
    unittest.main()
