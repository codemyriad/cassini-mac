#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for scripts/check-brand-tokens.py."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('check_brand_tokens', ROOT / 'scripts/check-brand-tokens.py')
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class BrandTokenSyncTests(unittest.TestCase):
    def make_tree(self) -> Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        (base / 'Cassini/Resources/Brand').mkdir(parents=True)
        (base / 'Cassini/Theme').mkdir(parents=True)
        shutil.copy2(ROOT / 'Cassini/Resources/Brand/tokens.json', base / 'Cassini/Resources/Brand/tokens.json')
        shutil.copy2(ROOT / 'Cassini/Resources/Brand/UPSTREAM.json', base / 'Cassini/Resources/Brand/UPSTREAM.json')
        shutil.copy2(ROOT / 'Cassini/Theme/CassiniTokens.swift', base / 'Cassini/Theme/CassiniTokens.swift')
        return base

    def test_real_repository_passes(self) -> None:
        self.assertEqual(checker.verify(ROOT), 33)

    def test_camel_case_keeps_digits(self) -> None:
        self.assertEqual(checker.camel_case('ink-2'), 'ink2')
        self.assertEqual(checker.camel_case('accent-strong'), 'accentStrong')
        self.assertEqual(checker.camel_case('on-inverse'), 'onInverse')

    def test_sha256_mismatch_fails(self) -> None:
        base = self.make_tree()
        tokens = base / 'Cassini/Resources/Brand/tokens.json'
        tokens.write_text(tokens.read_text(encoding='utf-8') + '\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            checker.verify(base)

    def test_missing_commit_header_fails(self) -> None:
        base = self.make_tree()
        pin = json.loads((base / 'Cassini/Resources/Brand/UPSTREAM.json').read_text(encoding='utf-8'))
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        lines = swift.read_text(encoding='utf-8').splitlines()
        lines[2] = '// commit removed'
        swift.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, pin['commit']):
            checker.verify(base)

    def test_light_or_dark_hex_drift_fails(self) -> None:
        for old, new in [('#007999', '#007998'), ('#83CDDF', '#83CDDE'), ('#070B1173', '#070B1172')]:
            with self.subTest(old=old, new=new):
                base = self.make_tree()
                swift = base / 'Cassini/Theme/CassiniTokens.swift'
                swift.write_text(swift.read_text(encoding='utf-8').replace(old, new, 1), encoding='utf-8')
                with self.assertRaisesRegex(ValueError, 'drift'):
                    checker.verify(base)

    def test_missing_active_token_fails(self) -> None:
        base = self.make_tree()
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        filtered = [line for line in swift.read_text(encoding='utf-8').splitlines() if 'scrimEntry' not in line and '.scrim' not in line]
        swift.write_text('\n'.join(filtered) + '\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, "missing=\\['scrim'\\]"):
            checker.verify(base)

    def test_proposed_speaker_token_is_rejected(self) -> None:
        base = self.make_tree()
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        injected = swift.read_text(encoding='utf-8').replace(
            '    static let entries: [Entry] = [',
            '    static let speaker1Entry = Entry(id: "speaker-1", swiftName: "speaker1", light: "#00697B", dark: "#83CDDF")\n'
            '    static let entries: [Entry] = [',
        )
        swift.write_text(injected, encoding='utf-8')
        with self.assertRaisesRegex(ValueError, "Non-active token 'speaker-1'"):
            checker.verify(base)

    def test_duplicate_hex_literal_outside_entry_table_is_rejected(self) -> None:
        base = self.make_tree()
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        injected = swift.read_text(encoding='utf-8').replace(
            'enum CassiniTheme {',
            'enum CassiniTheme {\n    static let duplicateHex = "#007999"',
        )
        swift.write_text(injected, encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Hex literal hard-coded outside CassiniTokens Entry table'):
            checker.verify(base)


if __name__ == '__main__':
    unittest.main()
