#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for scripts/check-brand-tokens.py and scripts/generate-brand-tokens.py."""
from __future__ import annotations

import hashlib
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
        (base / 'Cassini/Views').mkdir(parents=True)
        (base / 'Sources/CassiniSpectrogram').mkdir(parents=True)
        shutil.copy2(ROOT / 'Cassini/Resources/Brand/tokens.json', base / 'Cassini/Resources/Brand/tokens.json')
        shutil.copy2(ROOT / 'Cassini/Resources/Brand/UPSTREAM.json', base / 'Cassini/Resources/Brand/UPSTREAM.json')
        shutil.copy2(ROOT / 'Cassini/Resources/Brand/marks-UPSTREAM.json', base / 'Cassini/Resources/Brand/marks-UPSTREAM.json')
        for mark in ('saturn-nav.svg', 'saturn-mid.svg', 'saturn-full.svg', 'mark-flat.svg'):
            shutil.copy2(ROOT / 'Cassini/Resources/Brand' / mark, base / 'Cassini/Resources/Brand' / mark)
        shutil.copy2(ROOT / 'Cassini/Theme/CassiniTokens.swift', base / 'Cassini/Theme/CassiniTokens.swift')
        shutil.copy2(ROOT / 'Cassini/Theme/CassiniTheme.swift', base / 'Cassini/Theme/CassiniTheme.swift')
        return base

    def test_real_repository_passes(self) -> None:
        self.assertEqual(checker.verify(ROOT), 53)
        doc = json.loads((ROOT / 'Cassini/Resources/Brand/tokens.json').read_text(encoding='utf-8'))
        self.assertEqual(len(doc['tokens']), 53)
        self.assertEqual(doc.get('exceptions'), [])
        for block in ('tokens', 'derived'):
            for tid, spec in doc.get(block, {}).items():
                self.assertEqual(spec.get('status'), 'decided', tid)
                self.assertNotIn('check', spec, tid)

    def test_camel_case_keeps_digits(self) -> None:
        self.assertEqual(checker.camel_case('ink-2'), 'ink2')
        self.assertEqual(checker.camel_case('speaker-0'), 'speaker0')
        self.assertEqual(checker.camel_case('avatar-6'), 'avatar6')
        self.assertEqual(checker.camel_case('error-fill'), 'errorFill')
        self.assertEqual(checker.camel_case('card-rest'), 'cardRest')
        self.assertEqual(checker.camel_case('sidebar-mac'), 'sidebarMac')
        self.assertEqual(checker.camel_case('field-line'), 'fieldLine')

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
        lines[3] = '// Commit removed'
        swift.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, pin['commit']):
            checker.verify(base)

    def test_light_or_dark_hex_drift_fails(self) -> None:
        for old, new in [('#093351', '#093350'), ('#83CDDF', '#83CDDE'), ('#070B1173', '#070B1172'), ('#FAFAFB', '#FAFAFA')]:
            with self.subTest(old=old, new=new):
                base = self.make_tree()
                swift = base / 'Cassini/Theme/CassiniTokens.swift'
                swift.write_text(swift.read_text(encoding='utf-8').replace(old, new, 1), encoding='utf-8')
                with self.assertRaisesRegex(ValueError, 'drift'):
                    checker.verify(base)

    def test_hand_edit_to_generated_file_fails(self) -> None:
        base = self.make_tree()
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        swift.write_text(swift.read_text(encoding='utf-8') + '// hand edit\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'generate-brand-tokens.py'):
            checker.verify(base)

    def test_missing_active_token_fails(self) -> None:
        base = self.make_tree()
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        filtered = [line for line in swift.read_text(encoding='utf-8').splitlines() if 'scrimEntry' not in line and '.scrim' not in line]
        swift.write_text('\n'.join(filtered) + '\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, "missing=\\['scrim'\\]"):
            checker.verify(base)

    def test_non_active_proposed_token_is_rejected(self) -> None:
        base = self.make_tree()
        tokens_path = base / 'Cassini/Resources/Brand/tokens.json'
        upstream_path = base / 'Cassini/Resources/Brand/UPSTREAM.json'
        doc = json.loads(tokens_path.read_text(encoding='utf-8'))
        doc['tokens']['future-role'] = {'light': '#112233', 'dark': '#445566', 'status': 'proposed'}
        raw = (json.dumps(doc, indent=2) + '\n').encode('utf-8')
        tokens_path.write_bytes(raw)
        pin = json.loads(upstream_path.read_text(encoding='utf-8'))
        pin['sha256'] = hashlib.sha256(raw).hexdigest()
        upstream_path.write_text(json.dumps(pin, indent=2) + '\n', encoding='utf-8')
        swift = base / 'Cassini/Theme/CassiniTokens.swift'
        swift.write_text(checker.render_swift(base), encoding='utf-8')
        self.assertEqual(checker.verify(base), 53)
        injected = swift.read_text(encoding='utf-8').replace(
            '    static let entries: [Entry] = [',
            '    static let futureRoleEntry = Entry(id: "future-role", swiftName: "futureRole", light: "#112233", dark: "#445566")\n'
            '    static let entries: [Entry] = [',
        )
        swift.write_text(injected, encoding='utf-8')
        with self.assertRaisesRegex(ValueError, "Non-active token 'future-role'"):
            checker.verify(base)

    def test_stray_colour_literals_in_app_and_sources_fail(self) -> None:
        cases = [
            ('Cassini/Views/Sample.swift', 'import SwiftUI\nlet x = Color(red: 0.1, green: 0.2, blue: 0.3)\n', 'RGB Color/NSColor initializer'),
            ('Cassini/Views/Hex.swift', 'let raw = "#C01C28"\n', '#RRGGBB colour hex literal'),
            ('Cassini/Views/Sys.swift', 'import AppKit\nlet c = NSColor.systemRed\n', 'platform system colour literal'),
            ('Sources/CassiniSpectrogram/Sample.swift', 'let c: UInt32 = 0xd70015\n', '0xRRGGBB colour hex literal'),
        ]
        for rel, content, expected in cases:
            with self.subTest(rel=rel):
                base = self.make_tree()
                target = base / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content, encoding='utf-8')
                with self.assertRaisesRegex(ValueError, expected):
                    checker.verify(base)

    def test_unapplied_token_accounting_and_pr_b_theme_literal_gate(self) -> None:
        base = self.make_tree()
        theme = base / 'Cassini/Theme/CassiniTheme.swift'
        doc = json.loads((base / 'Cassini/Resources/Brand/tokens.json').read_text(encoding='utf-8'))
        all_ids = [
            tid
            for block in ('tokens', 'derived')
            for tid, spec in doc.get(block, {}).items()
            if spec.get('status') in {'decided', 'placeholder'}
        ]
        # Dropping a decided token from unappliedDecidedTokens without wiring CassiniTokens.<role> fails.
        refs_without_error_fill = '\n'.join(
            f'    static let ref_{checker.camel_case(tid)} = CassiniTokens.{checker.camel_case(tid)}'
            for tid in all_ids
            if tid != 'error-fill'
        )
        theme.write_text(
            'enum CassiniTheme {\n'
            '    static let unappliedDecidedTokens: Set<String> = []\n'
            f'{refs_without_error_fill}\n'
            '}\n',
            encoding='utf-8',
        )
        with self.assertRaisesRegex(ValueError, "Active token 'error-fill' is not in unappliedDecidedTokens"):
            checker.verify(base)
        # Once unappliedDecidedTokens is empty, colour literals inside CassiniTheme.swift fail too.
        refs = '\n'.join(
            f'    static let ref_{checker.camel_case(tid)} = CassiniTokens.{checker.camel_case(tid)}'
            for tid in all_ids
        )
        theme.write_text(
            'enum CassiniTheme {\n'
            '    static let unappliedDecidedTokens: Set<String> = []\n'
            f'{refs}\n'
            '    static let bad = Color(red: 1, green: 0, blue: 0)\n'
            '}\n',
            encoding='utf-8',
        )
        with self.assertRaisesRegex(ValueError, 'Cassini/Theme/CassiniTheme.swift'):
            checker.verify(base)

    def test_mark_svg_sha256_mismatch_fails(self) -> None:
        base = self.make_tree()
        nav = base / 'Cassini/Resources/Brand/saturn-nav.svg'
        nav.write_text(nav.read_text(encoding='utf-8') + '\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'saturn-nav.svg SHA-256 mismatch'):
            checker.verify(base)


if __name__ == '__main__':
    unittest.main()
