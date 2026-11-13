#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bundle the exact reviewed runtime files, public key and GPL text; no tests."""
from pathlib import Path
import argparse, hashlib, json, shutil, stat, subprocess, sys

ROOT = Path(__file__).resolve().parent.parent

def manifest_references(manifest):
    """Every packaged path the browser loads by name from manifest.json."""
    refs = set(manifest.get('icons', {}).values())
    action = manifest.get('action', {})
    refs |= set(action.get('default_icon', {}).values())
    if 'default_popup' in action: refs.add(action['default_popup'])
    if 'service_worker' in manifest.get('background', {}): refs.add(manifest['background']['service_worker'])
    for script in manifest.get('content_scripts', []): refs |= set(script.get('js', [])) | set(script.get('css', []))
    for resource in manifest.get('web_accessible_resources', []): refs |= set(resource.get('resources', []))
    return refs

def reviewed_files():
    subprocess.run([sys.executable, str(ROOT/'browser-protocol/verify.py'), '--pinned', str(ROOT/'BrowserExtension')], check=True)
    files = {}
    for line in (ROOT/'browser-protocol/SHA256SUMS').read_text().splitlines():
        digest, relative = line.split('  ',1)
        if not relative.startswith('extension/'): continue
        name = Path(relative.removeprefix('extension/'))
        if name.parts[0] == 'tests': continue
        source = ROOT/'BrowserExtension'/name
        assert not source.is_symlink() and hashlib.sha256(source.read_bytes()).hexdigest() == digest
        files[name] = source
    present = {p.relative_to(ROOT/'BrowserExtension') for p in (ROOT/'BrowserExtension').rglob('*')
               if p.is_file() and p.relative_to(ROOT/'BrowserExtension').parts[0] != 'tests'}
    # A runtime file vendored without a SHA256SUMS line would otherwise be
    # silently left out of the app, shipping a companion that differs from
    # the reviewed BrowserExtension/ checkout.
    assert present == set(files), 'Unreviewed companion runtime: '+', '.join(sorted(map(str, present ^ set(files))))
    missing = sorted(manifest_references(json.loads(files[Path('manifest.json')].read_text())) - {n.as_posix() for n in files})
    assert not missing, 'Manifest references unbundled files: '+', '.join(missing)
    files[Path('COPYING')] = ROOT/'COPYING'
    files[Path('PROTOCOL_COMMIT.txt')] = ROOT/'browser-protocol/PINNED_COMMIT'
    return files

def check(destination, files=None):
    files = reviewed_files() if files is None else files
    assert destination.is_dir() and not destination.is_symlink(), 'Missing bundled companion'
    entries = list(destination.rglob('*'))
    assert all(not p.is_symlink() for p in entries), 'Linked companion payload'
    assert all(stat.S_IMODE(p.stat().st_mode) & 0o022 == 0 for p in [destination,*entries]), 'Writable companion payload'
    assert {p.relative_to(destination) for p in entries if p.is_file()} == set(files), 'Unexpected companion payload'
    for name, source in files.items():
        assert (destination/name).read_bytes() == source.read_bytes(), 'Changed companion: '+str(name)
    print('Verified exact bundled companion runtime, licence and protocol pin')

def bundle(destination):
    files = reviewed_files()
    stage = destination.with_name(destination.name+'.staging')
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(mode=0o755,parents=True)
    for name, source in files.items():
        target = stage/name; target.parent.mkdir(mode=0o755,parents=True,exist_ok=True); shutil.copy2(source,target)
        # Git archives can retain group-writable modes. The installed app's
        # reviewed runtime must pass the native installer's no-group-write rule.
        target.chmod(0o644)
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
