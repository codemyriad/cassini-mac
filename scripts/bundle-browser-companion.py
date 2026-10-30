#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bundle the exact reviewed runtime files, public key and GPL text; no tests."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess

ROOT = Path(__file__).resolve().parent.parent

def reviewed_files():
    subprocess.run(['python3', str(ROOT/'browser-protocol/verify.py'), '--pinned', str(ROOT/'BrowserExtension')], check=True)
    files = {}
    for line in (ROOT/'browser-protocol/SHA256SUMS').read_text().splitlines():
        digest, relative = line.split('  ',1)
        if not relative.startswith('extension/'): continue
        name = Path(relative.removeprefix('extension/'))
        if name.parts[0] == 'tests': continue
        source = ROOT/'BrowserExtension'/name
        assert not source.is_symlink() and hashlib.sha256(source.read_bytes()).hexdigest() == digest
        files[name] = source
    files[Path('COPYING')] = ROOT/'COPYING'
    files[Path('PROTOCOL_COMMIT.txt')] = ROOT/'browser-protocol/PINNED_COMMIT'
    return files

def check(destination, files=None):
    files = reviewed_files() if files is None else files
    assert destination.is_dir() and not destination.is_symlink(), 'Missing bundled companion'
    entries = list(destination.rglob('*'))
    assert all(not p.is_symlink() for p in entries), 'Linked companion payload'
    assert {p.relative_to(destination) for p in entries if p.is_file()} == set(files), 'Unexpected companion payload'
    for name, source in files.items():
        assert (destination/name).read_bytes() == source.read_bytes(), 'Changed companion: '+str(name)
    print('Verified exact bundled companion runtime, licence and protocol pin')

def bundle(destination):
    files = reviewed_files()
    stage = destination.with_name(destination.name+'.staging')
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    for name, source in files.items():
        target = stage/name; target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source,target)
    manifest=json.loads((stage/'manifest.json').read_text())
    assert manifest['key'] and manifest['minimum_chrome_version']=='116'
    check(stage, files)
    if destination.exists(): shutil.rmtree(destination)
    stage.rename(destination)
    print('Bundled reviewed companion',manifest['version'])

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('destination',type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    (check if args.check else bundle)(args.destination)
