#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Export every LibraryBoards PNG attachment (27 light + 27 dark pairs) and write shots.json."""
from __future__ import annotations
import argparse, json, os, platform, re, shutil, struct, subprocess, zlib
from pathlib import Path

PNG_SIG = b'\x89PNG\r\n\x1a\n'
KEY_RE = re.compile(r'[a-z0-9][a-z0-9.-]{0,159}')
NAME_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9-]*')
LANG_RE = re.compile(r'-(en-GB|fr-FR|pt-PT|pt-BR|es-ES|it-IT|fr|es|it)$')
CORE_ORDER = {n: i for i, n in enumerate(('library', 'recording', 'meeting', 'search', 'settings-recording', 'settings-transcription'))}

EXPECTED_BOARDS = frozenset((
    'library', 'library-fr', 'first-run', 'first-run-fr', 'record-first', 'record-first-fr',
    'meeting', 'meeting-open', 'meeting-find', 'meeting-scrolled', 'meeting-summary', 'recording', 'received', 'export', 'export-success', 'search',
    'settings-recording', 'settings-transcription', 'settings-parakeet-recommendation-en-GB',
    'settings-parakeet-recommendation-fr-FR', 'settings-parakeet-recommendation-pt-PT',
    'companion-setup', 'what-is-recorded', 'trash', 'trash-meeting', 'trash-after', 'rename',
    'recording-details', 'recording-details-many', 'listening-bar-finished', 'listening-transcript-highlight',
))


def parse_screen(name: str) -> tuple[str, str, str]:
    m = LANG_RE.search(name)
    stem, tag = (name[:m.start()], m.group(1)) if m else (name, '')
    lang = {'': 'en', 'en-GB': 'en', 'fr-FR': 'fr', 'es-ES': 'es', 'it-IT': 'it'}.get(tag, tag.lower())
    suffix = '' if lang == 'en' else f' ({tag if tag.startswith("pt-") else lang})'
    screen = stem.lower()
    return screen, lang, screen.replace('-', ' ').capitalize().replace('parakeet', 'Parakeet') + suffix


def shot_key(row: dict) -> str:
    value = '.'.join([row['screen'], row['scheme']] + ([row['lang'].lower()] if row['lang'] != 'en' else []))
    assert KEY_RE.fullmatch(value), f'Invalid shot key: {value}'
    return value


def top_luma_and_pixels(data: bytes, max_rows: int = 32) -> tuple[float, bytes]:
    assert data[:8] == PNG_SIG and data[12:16] == b'IHDR', 'Invalid PNG header'
    width, height, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', data[16:29])
    assert (comp, filt, interlace) == (0, 0, 0) and depth in (8, 16) and color in (2, 6), (depth, color, interlace)
    pos, idat = 8, bytearray()
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        if kind == b'IDAT':
            idat.extend(data[pos + 8:pos + 8 + length])
        elif kind == b'IEND':
            break
        pos += 12 + length
    channels = 3 if color == 2 else 4
    step = depth // 8
    bpp, rows = channels * step, min(height, max_rows)
    stride = width * bpp
    need = (1 + stride) * rows
    raw = zlib.decompressobj().decompress(bytes(idat), need)
    assert len(raw) == need, (len(raw), need)
    prev, cur, out = bytearray(stride), bytearray(stride), bytearray(stride * rows)
    mv = memoryview(raw)
    luma_sum = opaque = 0
    for y in range(rows):
        base = y * (1 + stride)
        f, row = raw[base], mv[base + 1:base + 1 + stride]
        assert 0 <= f <= 4, f'Unsupported PNG filter {f}'
        if f == 0:
            cur[:] = row
        else:
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
                if f == 4:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    p = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                else:
                    p = (0, a, b, (a + b) >> 1)[f]
                cur[i] = (row[i] + p) & 0xFF
        out[y * stride:(y + 1) * stride] = cur
        for px in range(0, stride, bpp):
            if channels == 3 or cur[px + 3 * step] > 0:
                luma_sum += cur[px] + cur[px + step] + cur[px + 2 * step]
                opaque += 1
        prev, cur = cur, prev
    assert opaque > 0, 'Completely transparent screenshot'
    return luma_sum / (3.0 * opaque), bytes(out)


def runner_info() -> dict[str, str]:
    os_ver, os_build = platform.mac_ver()[0], ''
    if os_ver:
        try:
            os_build = subprocess.check_output(['sw_vers', '-buildVersion'], text=True, timeout=5).strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return {'os_version': os_ver or platform.release(), 'os_build': os_build,
            'image_os': os.environ.get('ImageOS', ''), 'image_version': os.environ.get('ImageVersion', '')}


def export_scheme(src: Path, target: Path, scheme: str) -> tuple[dict[str, bytes], list[dict]]:
    src_root = src.resolve()
    manifest = json.loads((src_root / 'manifest.json').read_text())
    (target if scheme == 'light' else target / 'dark').mkdir(parents=True, exist_ok=True)
    pngs, rows = {}, []
    for test in manifest:
        test_id = test.get('testIdentifier', '')
        for att in test.get('attachments', []):
            human = att.get('suggestedHumanReadableName', '')
            if att.get('isAssociatedWithFailure') or not human.endswith('.png'):
                continue
            name = re.sub(r'_\d+_[^/]+$', '', human[:-4])
            if name == 'save-panel-failure':
                continue
            assert NAME_RE.fullmatch(name), f'Invalid screenshot name: {name!r}'
            assert name not in pngs, f'Duplicate {scheme} screenshot: {name}'
            path = (src_root / att['exportedFileName']).resolve()
            assert path.is_relative_to(src_root), f'Unsafe attachment path: {att["exportedFileName"]}'
            data = path.read_bytes()
            assert data[:8] == PNG_SIG and data[12:16] == b'IHDR', name
            width, height = struct.unpack('>II', data[16:24])
            if name.startswith('settings-'):
                assert width == 700 and 500 <= height <= 700, (name, width, height)
            else:
                assert (width, height) == (1120, 720), (name, width, height)
            rel = f'{name}.png' if scheme == 'light' else f'dark/{name}.png'
            (target / rel).write_bytes(data)
            pngs[name] = data
            screen, lang, label = parse_screen(name)
            row = {'screen': screen, 'label': label, 'scheme': scheme, 'lang': lang,
                   'device': 'desktop', 'path': rel, 'test': test_id, 'width': width, 'height': height}
            shot_key(row)
            rows.append(row)
            print(rel, f'{width}x{height}')
    return pngs, rows


def verify_manifest_and_pixels(rows: list[dict], light_pngs: dict[str, bytes], dark_pngs: dict[str, bytes], require_dark: bool) -> None:
    keys = [shot_key(r) for r in rows]
    assert len(keys) == len(set(keys)), f'Duplicate shot keys in manifest: {keys}'
    for r in rows:
        assert r['path'].startswith('dark/') == (r['scheme'] == 'dark'), f'Path/scheme mismatch: {r}'
    light_metrics = {}
    for name, raw in sorted(light_pngs.items()):
        luma, px = top_luma_and_pixels(raw)
        assert luma > 110.0, f'Light screenshot {name} rendered dark ({luma:.1f} <= 110.0)'
        light_metrics[name] = (luma, px)
    missing_light = sorted(EXPECTED_BOARDS - set(light_pngs))
    assert not missing_light, f'Missing light boards: {missing_light}'
    if require_dark:
        missing_dark = sorted(EXPECTED_BOARDS - set(dark_pngs))
        assert not missing_dark, f'Missing dark boards: {missing_dark}'
        by_screen: dict[tuple[str, str, str], set[str]] = {}
        for r in rows:
            by_screen.setdefault((r['screen'], r['lang'], r['device']), set()).add(r['scheme'])
        unpaired = sorted(k for k, schemes in by_screen.items() if schemes != {'light', 'dark'})
        assert not unpaired, f'Unpaired screens in shots.json: {unpaired}'
        for name, dark_bytes in sorted(dark_pngs.items()):
            assert name in light_metrics, f'Dark screenshot {name} has no light pair'
            light_luma, light_px = light_metrics[name]
            dark_luma, dark_px = top_luma_and_pixels(dark_bytes)
            assert dark_px != light_px, f'Dark screenshot {name} pixels match light'
            assert dark_luma < 110.0, f'Dark screenshot {name} rendered light ({dark_luma:.1f} >= 110.0)'
            assert dark_luma + 40.0 < light_luma, f'Dark screenshot {name} not darker than light ({dark_luma:.1f} vs {light_luma:.1f})'


def export_boards(source: Path, target: Path, dark_source: Path | None = None) -> dict:
    target.mkdir(parents=True, exist_ok=True)
    light_pngs, rows = export_scheme(source, target, 'light')
    dark_pngs: dict[str, bytes] = {}
    if dark_source is not None:
        dark_pngs, dark_rows = export_scheme(dark_source, target, 'dark')
        rows.extend(dark_rows)
    verify_manifest_and_pixels(rows, light_pngs, dark_pngs, require_dark=dark_source is not None)
    rows.sort(key=lambda r: (CORE_ORDER.get(r['screen'], 99), r['screen'], r['lang'], r['scheme'] != 'light'))
    shots_doc = {'version': 1, 'app': 'mac', 'runner': runner_info(), 'shots': rows}
    (target / 'shots.json').write_text(json.dumps(shots_doc, indent=2) + '\n')

    manifest = json.loads((source / 'manifest.json').read_text())
    payloads = [a for t in manifest for a in t.get('attachments', []) if a.get('suggestedHumanReadableName', '').startswith('recording-menu')]
    assert len(payloads) == 1, payloads
    payload = (source.resolve() / payloads[0]['exportedFileName']).resolve()
    assert payload.is_relative_to(source.resolve()), payloads[0]
    value = json.loads(payload.read_text())
    assert value['assertionHeld'] is True and [a['id'] for a in value['actions']] == ['stop', 'open', 'settings', 'quit']
    shutil.copyfile(payload, target / 'recording-menu.json')
    return shots_doc


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    parser.add_argument('--dark', type=Path, default=None)
    args = parser.parse_args()
    export_boards(args.source, args.target, args.dark)


if __name__ == '__main__':
    main()
