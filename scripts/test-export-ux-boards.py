#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for scripts/export-ux-boards.py (required light/dark pairs, luminance agreement, shots.json)."""
from __future__ import annotations
import importlib.util, json, os, struct, tempfile, unittest, zlib
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('export_ux_boards', Path(__file__).with_name('export-ux-boards.py'))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def make_png(width: int, height: int, rgba: tuple[int, int, int, int], filt: int = 0) -> bytes:
    chunk = lambda k, d: struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d) & 0xFFFFFFFF)
    r, g, b, a = rgba
    payload = ((bytes([0]) + bytes([r, g, b, a]) * width) * height if filt == 0 else
               bytes([4, r, g, b, a]) + bytes(4 * (width - 1)) + (bytes([4]) + bytes(4 * width)) * (height - 1))
    return (exporter.PNG_SIG + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(payload, level=1)) + chunk(b'IEND', b''))


class ExportUXBoardsTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix='cassini-export-boards-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.light, self.dark, self.out = self.root / 'light', self.root / 'dark', self.root / 'ux-boards'
        self.light.mkdir(); self.dark.mkdir()
        self._light_png, self._light_settings = make_png(1120, 720, (242, 241, 246, 255)), make_png(700, 520, (242, 241, 246, 255))
        self._dark_png, self._dark_settings = make_png(1120, 720, (28, 30, 36, 255), filt=4), make_png(700, 520, (28, 30, 36, 255), filt=4)

    def populate(self, extra_light=(), omit_light=(), extra_dark=(), omit_dark=(), light_rgba=None, dark_rgba=None) -> None:
        att = lambda fn, hr=None, fail=False: {'exportedFileName': fn, 'suggestedHumanReadableName': hr or fn, 'isAssociatedWithFailure': fail}
        light_entries = []
        for idx, name in enumerate(sorted(exporter.EXPECTED_BOARDS - set(omit_light)) + list(extra_light)):
            fn = f'{name}_0_00000000-0000-4000-8000-{idx:012d}.png'
            size_png = make_png(700 if name.startswith('settings-') else 1120, 520 if name.startswith('settings-') else 720, light_rgba) if light_rgba else (self._light_settings if name.startswith('settings-') else self._light_png)
            (self.light / fn).write_bytes(size_png)
            light_entries.append({'testIdentifier': f'LibraryBoards/test_{idx}()', 'attachments': [att(fn)]})
        (self.light / 'tree.txt').write_text('ax tree')
        (self.light / 'fail.png').write_bytes(make_png(1440, 900, (255, 0, 0, 255)))
        (self.light / 'menu.json').write_text(json.dumps({'assertionHeld': True, 'actions': [{'id': i} for i in ('stop', 'open', 'settings', 'quit')]}))
        light_entries.append({'testIdentifier': 'LibraryBoards/testExtras()', 'attachments': [
            att('tree.txt', 'meeting-accessibility-tree_0_uuid.txt'), att('fail.png', 'Screenshot_0_uuid.png', True),
            att('menu.json', 'recording-menu.json_0_uuid.json'),
        ]})
        (self.light / 'manifest.json').write_text(json.dumps(light_entries))
        dark_entries = []
        for idx, name in enumerate(sorted(exporter.EXPECTED_BOARDS - set(omit_dark)) + list(extra_dark)):
            fn = f'{name}_0_10000000-0000-4000-8000-{idx:012d}.png'
            size_png = make_png(700 if name.startswith('settings-') else 1120, 520 if name.startswith('settings-') else 720, dark_rgba) if dark_rgba else (self._dark_settings if name.startswith('settings-') else self._dark_png)
            (self.dark / fn).write_bytes(size_png)
            dark_entries.append({'testIdentifier': f'LibraryBoards/testDark_{idx}()', 'attachments': [att(fn)]})
        (self.dark / 'manifest.json').write_text(json.dumps(dark_entries))

    def test_exports_all_32_light_and_32_dark_pairs_and_writes_pr_shots_manifest(self) -> None:
        self.populate()
        with patch.dict(os.environ, {'ImageOS': 'macos15', 'ImageVersion': '20261110.1'}), patch('builtins.print'):
            doc = exporter.export_boards(self.light, self.out, self.dark)
        self.assertEqual((doc['app'], doc['runner']['image_os'], doc['runner']['image_version']), ('mac', 'macos15', '20261110.1'))
        shots = doc['shots']
        self.assertEqual(len(shots), 64)
        self.assertEqual({s['path'] for s in shots if s['scheme'] == 'light'}, {f'{n}.png' for n in exporter.EXPECTED_BOARDS})
        self.assertEqual({s['path'] for s in shots if s['scheme'] == 'dark'}, {f'dark/{n}.png' for n in exporter.EXPECTED_BOARDS})
        by_screen: dict[tuple[str, str, str], set[str]] = {}
        for s in shots:
            self.assertTrue((self.out / s['path']).is_file(), s['path'])
            self.assertRegex(exporter.shot_key(s), r'^[a-z0-9][a-z0-9.-]{0,159}$')
            by_screen.setdefault((s['screen'], s['lang'], s['device']), set()).add(s['scheme'])
        self.assertTrue(all(v == {'light', 'dark'} for v in by_screen.values()))
        by_path = {s['path']: s for s in shots}
        self.assertEqual((by_path['settings-parakeet-recommendation-pt-PT.png']['screen'], by_path['settings-parakeet-recommendation-pt-PT.png']['lang']),
                         ('settings-parakeet-recommendation', 'pt-pt'))
        self.assertEqual((by_path['dark/library-fr.png']['screen'], by_path['dark/library-fr.png']['lang']), ('library', 'fr'))
        self.assertTrue((self.out / 'recording-menu.json').is_file())
        self.assertEqual(json.loads((self.out / 'shots.json').read_text()), doc)

    def test_rejects_unpaired_mislabelled_duplicate_missing_or_unsafe_boards(self) -> None:
        for kwargs, pattern in (
            ({'extra_light': ('library',)}, 'Duplicate light screenshot: library'),
            ({'omit_light': ('listening-bar-finished',)}, 'Missing light boards'),
            ({'omit_dark': ('search',)}, 'Missing dark boards'),
            ({'extra_light': ('extra-board',)}, 'Unpaired screens in shots.json'),
            ({'dark_rgba': (242, 241, 246, 255)}, 'Dark screenshot .* pixels match light'),
            ({'dark_rgba': (200, 200, 200, 255)}, 'Dark screenshot .* rendered light'),
            ({'light_rgba': (28, 30, 36, 255)}, 'Light screenshot .* rendered dark'),
        ):
            self.populate(**kwargs)
            with patch('builtins.print'), self.assertRaisesRegex(AssertionError, pattern):
                exporter.export_boards(self.light, self.out, self.dark)
        self.populate()
        manifest = json.loads((self.dark / 'manifest.json').read_text())
        manifest[0]['attachments'][0]['exportedFileName'] = '../outside.png'
        (self.dark / 'manifest.json').write_text(json.dumps(manifest))
        with patch('builtins.print'), self.assertRaisesRegex(AssertionError, 'Unsafe attachment path'):
            exporter.export_boards(self.light, self.out, self.dark)


if __name__ == '__main__':
    unittest.main()
