#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bind same-run CI products to their source revision, pins and archive digest."""
import argparse
import hashlib
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
PRODUCTS = {
    'swiftpm': ['.build'],
    'assets': ['build/Whistle', 'build/Opus'],
    'debug': ['build/Build/Products/Debug', 'build/Build/Products'],
    'release': ['build/Build/Products/Release'],
}
PINS = ['Package.swift', 'Whistle/pins.json', 'scripts/fetch-opus.py', 'scripts/fetch-vad.py']


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def identity(kind):
    return dict(kind=kind, commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                xcode=subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                pins={name: digest(ROOT / name) for name in PINS},
                arch=os.uname().machine if kind == 'swiftpm' else 'universal')


def pack(kind, destination):
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (kind + '.tar.gz')
    paths = PRODUCTS[kind]
    if kind == 'debug':
        paths = ['build/Build/Products/Debug'] + [str(p.relative_to(ROOT)) for p in (ROOT/'build/Build/Products').glob('*.xctestrun')]
        if len(paths) < 2:
            raise ValueError('Missing build-for-testing test specification')
    with tarfile.open(archive, 'w:gz', compresslevel=1, dereference=False) as target:
        for name in paths:
            if not (ROOT/name).exists():
                raise ValueError('Missing product: ' + name)
            target.add(ROOT/name, arcname=name)
    metadata = identity(kind)
    metadata['sha256'] = digest(archive)
    (destination/(kind+'.json')).write_text(json.dumps(metadata, indent=2)+'\n')


def unpack(kind, source):
    metadata = json.loads((source/(kind+'.json')).read_text())
    expected = identity(kind)
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError('Product revision, architecture, Xcode or pins do not match checkout')
    archive = source/(kind+'.tar.gz')
    if digest(archive) != metadata['sha256']:
        raise ValueError('Product archive digest mismatch')
    allowed = ['.build'] if kind == 'swiftpm' else ['build']
    with tarfile.open(archive) as packed:
        members = packed.getmembers()
        for item in members:
            path = Path(item.name)
            if path.is_absolute() or '..' in path.parts or path.parts[0] not in allowed:
                raise ValueError('Unsafe product member: '+item.name)
            if item.issym() or item.islnk():
                link = Path(item.linkname)
                resolved = (ROOT/path.parent/link).resolve() if item.issym() else (ROOT/link).resolve()
                if link.is_absolute() or not resolved.is_relative_to(ROOT):
                    raise ValueError('Unsafe product link: '+item.name)
            elif not (item.isfile() or item.isdir()):
                raise ValueError('Unsupported product member: '+item.name)
        packed.extractall(ROOT, members=members)
    print('Restored verified', kind, 'products for', expected['commit'])


def stage_assets(kind, destination):
    """Only the producer uses this opt-in path; shipped code never uses CI state."""
    source = Path(os.environ['CASSINI_CI_ASSETS'])/kind
    hashes = json.loads((source/'unsigned-sha256.json').read_text())
    if kind == 'Whistle':
        if json.loads((source/'pins.json').read_text()) != json.loads((ROOT/'Whistle/pins.json').read_text()):
            raise ValueError('Whistle pin mismatch')
        spec = importlib.util.spec_from_file_location('ci_vad_pins', ROOT/'scripts/fetch-vad.py')
        vad = importlib.util.module_from_spec(spec); spec.loader.exec_module(vad)
        hashes['silero_vad.onnx'] = vad.SILERO_SHA
        hashes.update({name: sha for name, sha in vad.MEMBERS.values()})
    for name, expected in hashes.items():
        if Path(name).name != name or digest(source/name) != expected:
            raise ValueError('Staged asset digest mismatch: '+name)
    destination.mkdir(parents=True, exist_ok=True)
    for path in source.iterdir():
        if path.is_file():
            shutil.copy2(path, destination/path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['pack', 'unpack', 'stage-assets'])
    parser.add_argument('kind', choices=list(PRODUCTS)+['Whistle', 'Opus'])
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    if args.action == 'stage-assets':
        stage_assets(args.kind, args.directory)
    elif args.action == 'pack':
        pack(args.kind, args.directory)
    else:
        unpack(args.kind, args.directory)


if __name__ == '__main__':
    main()
