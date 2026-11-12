#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify vendored brand/tokens.json pin, SHA-256, and Swift token sheet parity."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent

ENTRY_RE = re.compile(
    r'static let (\w+)Entry\s*=\s*Entry\(\s*'
    r'id:\s*"([^"]+)",\s*'
    r'swiftName:\s*"([^"]+)",\s*'
    r'light:\s*"(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)",\s*'
    r'dark:\s*"(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)"\s*\)'
)
HEX_RE = re.compile(r'#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?\b')


def camel_case(token_id: str) -> str:
    return re.sub(r'-([a-z0-9])', lambda m: m.group(1).upper(), token_id)


def verify(root: Path = ROOT) -> int:
    brand_dir = root / 'Cassini/Resources/Brand'
    tokens_path = brand_dir / 'tokens.json'
    upstream_path = brand_dir / 'UPSTREAM.json'
    swift_path = root / 'Cassini/Theme/CassiniTokens.swift'

    if not tokens_path.is_file():
        raise ValueError(f'Missing vendored token file: {tokens_path}')
    if not upstream_path.is_file():
        raise ValueError(f'Missing upstream pin file: {upstream_path}')
    if not swift_path.is_file():
        raise ValueError(f'Missing Swift token sheet: {swift_path}')

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
    forbidden_tokens: set[str] = set()
    for token_id, spec in token_doc.get('tokens', {}).items():
        status = spec.get('status')
        if status in {'decided', 'placeholder'}:
            active_tokens[token_id] = (spec['light'].upper(), spec['dark'].upper())
        else:
            forbidden_tokens.add(token_id)
    for derived_id in token_doc.get('derived', {}):
        forbidden_tokens.add(derived_id)

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

    entries_block = re.search(r'static let entries:\s*\[Entry\]\s*=\s*\[(.*?)\]', swift_text, re.S)
    if not entries_block:
        raise ValueError('Missing `static let entries: [Entry]` in CassiniTokens.swift')
    listed_entries = re.findall(r'\b(\w+)Entry\b', entries_block.group(1))
    if len(listed_entries) != len(set(listed_entries)):
        raise ValueError(f'Duplicate entries in CassiniTokens.entries: {listed_entries}')

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
        if prop_prefix not in listed_entries:
            raise ValueError(f'{prop_prefix}Entry missing from CassiniTokens.entries')
        if not re.search(rf'static let {re.escape(swift_name)}\s*=\s*{re.escape(prop_prefix)}Entry\.nsColor\b', swift_text):
            raise ValueError(f'Missing NSColor accessor CassiniTokens.ns.{swift_name}')
        if not re.search(rf'static let {re.escape(swift_name)}\s*=\s*{re.escape(prop_prefix)}Entry\.color\b', swift_text):
            raise ValueError(f'Missing Color accessor CassiniTokens.{swift_name}')

    # Ensure no hex literals appear outside Entry(...) declarations, comments, or #if DEBUG self-tests.
    non_entry = ENTRY_RE.sub('', swift_text)
    non_entry = re.sub(r'#if DEBUG.*?#endif', '', non_entry, flags=re.S)
    non_entry = re.sub(r'//.*', '', non_entry)
    stray_hex = HEX_RE.findall(non_entry)
    if stray_hex:
        raise ValueError(f'Hex literal hard-coded outside CassiniTokens Entry table: {stray_hex}')

    return len(active_tokens)


def main() -> int:
    count = verify(ROOT)
    print(f'Verified {count} brand tokens (light + dark) and UPSTREAM.json SHA-256 pin')
    return 0


if __name__ == '__main__':
    sys.exit(main())
