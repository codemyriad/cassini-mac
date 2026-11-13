#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify vendored brand/tokens.json pin, generated CassiniTokens.swift parity, and zero stray colour literals."""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

_GEN_SPEC = importlib.util.spec_from_file_location(
    'generate_brand_tokens',
    Path(__file__).resolve().parent / 'generate-brand-tokens.py',
)
assert _GEN_SPEC and _GEN_SPEC.loader
_generator = importlib.util.module_from_spec(_GEN_SPEC)
_GEN_SPEC.loader.exec_module(_generator)
camel_case = _generator.camel_case
render_swift = _generator.render_swift

ENTRY_RE = re.compile(
    r'static let (\w+)Entry\s*=\s*Entry\(\s*'
    r'id:\s*"([^"]+)",\s*'
    r'swiftName:\s*"([^"]+)",\s*'
    r'light:\s*"(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)",\s*'
    r'dark:\s*"(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)"\s*\)'
)
UNAPPLIED_RE = re.compile(
    r'static let unappliedDecidedTokens:\s*Set<String>\s*=\s*\[(.*?)\]',
    re.S,
)

LITERAL_PATTERNS: list[tuple[str, re.Pattern[str], set[str]]] = [
    (
        'RGB Color/NSColor initializer',
        re.compile(r'\b(?:NS)?Color\s*\(\s*(?:srgbRed|red|calibratedRed|deviceRed)\s*:'),
        {'.swift'},
    ),
    (
        '0xRRGGBB colour hex literal',
        re.compile(r'\b0x[0-9A-Fa-f]{6}\b'),
        {'.swift'},
    ),
    (
        '#RRGGBB colour hex literal',
        re.compile(r'#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?\b'),
        {'.swift', '.html', '.css'},
    ),
    (
        'platform system colour literal',
        re.compile(
            r'\b(?:NSColor\.)?system(?:Red|Orange|Yellow|Green|Mint|Teal|Cyan|Blue|Indigo|Purple|Pink|Brown|Gray)\b'
            r'|(?<!\w)(?:Color)?\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown)\b'
        ),
        {'.swift'},
    ),
    (
        'CSS rgb/hsl colour literal',
        re.compile(r'\b(?:rgba?|hsla?)\s*\('),
        {'.html', '.css'},
    ),
]


def _verify_upstream_gh(commit: str, raw_tokens: bytes) -> None:
    proc = subprocess.run(
        ['gh', 'api', f'repos/codemyriad/cassini-ux/contents/brand/tokens.json?ref={commit}', '--jq', '.content'],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise ValueError(f'gh api upstream fetch failed for cassini-ux@{commit}: {proc.stderr.strip()}')
    upstream_bytes = base64.b64decode(proc.stdout)
    if upstream_bytes != raw_tokens:
        raise ValueError(f'Vendored tokens.json differs from codemyriad/cassini-ux@{commit}')


def _scan_colour_literals(root: Path, allow_pre_w1_compat: bool) -> None:
    allowed_rel = {'Cassini/Theme/CassiniTokens.swift'}
    if allow_pre_w1_compat:
        allowed_rel.update({'Cassini/Theme/CassiniTheme.swift', 'Cassini/Resources/Cassini.html'})

    skip_prefixes = (
        'Sources/CassiniZstd/upstream/',
        'Cassini/Resources/Licenses/',
        'Cassini/Resources/Brand/',
        'Cassini/Resources/UX/',
    )

    for folder_name in ('Cassini', 'Sources'):
        folder = root / folder_name
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob('*')):
            if not path.is_file() or path.suffix not in {'.swift', '.html', '.css'}:
                continue
            rel = path.relative_to(root).as_posix()
            if rel in allowed_rel or any(rel.startswith(prefix) for prefix in skip_prefixes):
                continue
            text = path.read_text(encoding='utf-8')
            for lineno, line in enumerate(text.splitlines(), 1):
                code = line.split('//', 1)[0] if path.suffix == '.swift' else line
                for kind, rx, suffixes in LITERAL_PATTERNS:
                    if path.suffix not in suffixes:
                        continue
                    match = rx.search(code)
                    if match:
                        raise ValueError(
                            f'Forbidden {kind} {match.group(0)!r} outside CassiniTokens.swift at {rel}:{lineno}'
                        )


def verify(root: Path = ROOT) -> int:
    brand_dir = root / 'Cassini/Resources/Brand'
    tokens_path = brand_dir / 'tokens.json'
    upstream_path = brand_dir / 'UPSTREAM.json'
    swift_path = root / 'Cassini/Theme/CassiniTokens.swift'
    theme_path = root / 'Cassini/Theme/CassiniTheme.swift'

    if not tokens_path.is_file():
        raise ValueError(f'Missing vendored token file: {tokens_path}')
    if not upstream_path.is_file():
        raise ValueError(f'Missing upstream pin file: {upstream_path}')
    if not swift_path.is_file():
        raise ValueError(f'Missing Swift token sheet: {swift_path}')
    if not theme_path.is_file():
        raise ValueError(f'Missing Swift theme file: {theme_path}')

    pin = json.loads(upstream_path.read_text(encoding='utf-8'))
    if pin.get('repository') != 'cassini-ux' or pin.get('path') != 'brand/tokens.json':
        raise ValueError(f'Unexpected UPSTREAM.json target: {pin}')
    commit = pin.get('commit', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError(f'Invalid UPSTREAM.json commit SHA: {commit!r}')

    raw_tokens = tokens_path.read_bytes()
    digest = hashlib.sha256(raw_tokens).hexdigest()
    if digest != pin.get('sha256', '').lower():
        raise ValueError(f'tokens.json SHA-256 mismatch: got {digest}, UPSTREAM.json has {pin.get("sha256")}')

    marks_pin_path = brand_dir / 'marks-UPSTREAM.json'
    if not marks_pin_path.is_file():
        raise ValueError(f'Missing brand marks pin file: {marks_pin_path}')
    marks_pin = json.loads(marks_pin_path.read_text(encoding='utf-8'))
    if marks_pin.get('cassiniUxCommit') != commit:
        raise ValueError(f'marks-UPSTREAM.json cassiniUxCommit must equal {commit}')
    expected_marks = {'saturn-nav.svg', 'saturn-mid.svg', 'saturn-full.svg', 'mark-flat.svg'}
    files_map = marks_pin.get('files', {})
    if set(files_map) != expected_marks:
        raise ValueError(f'marks-UPSTREAM.json files must be {sorted(expected_marks)}, got {sorted(files_map)}')
    for mark_name, mark_info in sorted(files_map.items()):
        mark_path = brand_dir / mark_name
        if not mark_path.is_file():
            raise ValueError(f'Missing vendored brand mark: {mark_path}')
        mark_bytes = mark_path.read_bytes()
        mark_sha = hashlib.sha256(mark_bytes).hexdigest()
        if mark_sha != mark_info.get('sha256', '').lower():
            raise ValueError(f'{mark_name} SHA-256 mismatch: got {mark_sha}, marks-UPSTREAM.json has {mark_info.get("sha256")}')

    if os.environ.get('CASSINI_VERIFY_UPSTREAM_GH') == '1':
        _verify_upstream_gh(commit, raw_tokens)

    token_doc = json.loads(raw_tokens.decode('utf-8'))
    if token_doc.get('schema') != 'cassini-ux/brand-tokens@1':
        raise ValueError(f'Unexpected token schema: {token_doc.get("schema")!r}')
    if token_doc.get('modes') != ['light', 'dark']:
        raise ValueError(f'Unexpected token modes: {token_doc.get("modes")!r}')

    swift_text = swift_path.read_text(encoding='utf-8')
    header_lines = '\n'.join(swift_text.splitlines()[:8])
    if commit not in header_lines:
        raise ValueError(f'CassiniTokens.swift header must name cassini-ux commit {commit}')
    if f'static let upstreamCommit = "{commit}"' not in swift_text:
        raise ValueError(f'CassiniTokens.upstreamCommit must equal {commit}')

    active_tokens: dict[str, tuple[str, str]] = {}
    base_active_count = 0
    derived_active_count = 0
    forbidden_tokens: set[str] = set()
    for block_name in ('tokens', 'derived'):
        for token_id, spec in token_doc.get(block_name, {}).items():
            if 'check' in spec:
                raise ValueError(f'Provisional check key must not appear on token {token_id!r}')
            status = spec.get('status')
            if status in {'decided', 'placeholder'}:
                active_tokens[token_id] = (spec['light'].upper(), spec['dark'].upper())
                if block_name == 'tokens':
                    base_active_count += 1
                else:
                    derived_active_count += 1
            else:
                forbidden_tokens.add(token_id)

    if base_active_count != 53:
        raise ValueError(f'Expected 53 active colours in tokens block, got {base_active_count}')

    parsed_entries: dict[str, tuple[str, str, str, str]] = {}
    for prop_prefix, token_id, swift_name, light, dark in ENTRY_RE.findall(swift_text):
        if token_id in parsed_entries:
            raise ValueError(f'Duplicate token entry in CassiniTokens.swift: {token_id}')
        if prop_prefix != swift_name:
            raise ValueError(f'Entry constant {prop_prefix}Entry must match swiftName {swift_name}')
        parsed_entries[token_id] = (swift_name, light.upper(), dark.upper(), prop_prefix)

    for forbidden in sorted(forbidden_tokens):
        if forbidden in parsed_entries:
            raise ValueError(f'Non-active token {forbidden!r} must not appear in CassiniTokens.swift')

    missing = sorted(set(active_tokens) - set(parsed_entries))
    extra = sorted(set(parsed_entries) - set(active_tokens))
    if missing or extra:
        raise ValueError(f'Token set mismatch: missing={missing}, extra={extra}')

    for token_id, (want_light, want_dark) in sorted(active_tokens.items()):
        swift_name, got_light, got_dark, prop_prefix = parsed_entries[token_id]
        expected_swift = camel_case(token_id)
        if swift_name != expected_swift:
            raise ValueError(f'Token {token_id!r} must map to camelCase {expected_swift!r}, got {swift_name!r}')
        if (got_light, got_dark) != (want_light, want_dark):
            raise ValueError(
                f'Token {token_id!r} drift: tokens.json=({want_light}, {want_dark}) '
                f'vs CassiniTokens.swift=({got_light}, {got_dark})'
            )
        if not re.search(rf'static let {re.escape(swift_name)}\s*=\s*{re.escape(prop_prefix)}Entry\.nsColor\b', swift_text):
            raise ValueError(f'Missing NSColor accessor CassiniTokens.ns.{swift_name}')
        if not re.search(rf'static let {re.escape(swift_name)}\s*=\s*{re.escape(prop_prefix)}Entry\.color\b', swift_text):
            raise ValueError(f'Missing Color accessor CassiniTokens.{swift_name}')

    expected_swift_text = render_swift(root)
    if swift_text != expected_swift_text:
        raise ValueError(
            'CassiniTokens.swift differs from scripts/generate-brand-tokens.py output; '
            'regenerate instead of editing by hand'
        )

    theme_text = theme_path.read_text(encoding='utf-8')
    unapplied_match = UNAPPLIED_RE.search(theme_text)
    if not unapplied_match:
        raise ValueError('Missing `static let unappliedDecidedTokens: Set<String>` in CassiniTheme.swift')
    unapplied_ids = set(re.findall(r'"([^"]+)"', unapplied_match.group(1)))
    unknown_unapplied = sorted(unapplied_ids - set(active_tokens))
    if unknown_unapplied:
        raise ValueError(f'Unknown token IDs in CassiniTheme.unappliedDecidedTokens: {unknown_unapplied}')

    for token_id in sorted(set(active_tokens) - unapplied_ids):
        swift_name = camel_case(token_id)
        ref_re = re.compile(rf'\bCassiniTokens\.(?:ns\.)?{re.escape(swift_name)}(?:Entry)?\b')
        if not ref_re.search(theme_text):
            raise ValueError(
                f'Active token {token_id!r} is not in unappliedDecidedTokens and is not wired in CassiniTheme.swift'
            )

    _scan_colour_literals(root, allow_pre_w1_compat=bool(unapplied_ids))
    return base_active_count


def main() -> int:
    count = verify(ROOT)
    print(f'Verified {count} brand colours (+ derived roles, light + dark), generator parity, and literal check')
    return 0


if __name__ == '__main__':
    sys.exit(main())
