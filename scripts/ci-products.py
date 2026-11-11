#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bind same-run CI products to their source revision, pins and archive digest."""
import argparse
import sys
import hashlib
import json
import re
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
    'parakeet': ['build/Parakeet', 'build/ParakeetModel'],
    # The Parakeet runtime alone (no model), for the Release build (D66 mac-P2-2).
    'runtime': ['build/Parakeet'],
    'debug': ['build/Build/Products/Debug', 'build/Build/Products'],
    'release': ['build/Build/Products/Release'],
}
PINS = ['project.yml', 'scripts/fetch-sparkle.py', 'Distribution/sparkle-public-key.txt', 'Package.swift', 'Whistle/pins.json', 'Opus/pins.json', 'scripts/fetch-opus.py', 'scripts/fetch-vad.py', 'Parakeet/pins.json', 'Parakeet/UPSTREAM.json', 'Parakeet/model-manifest.json']


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
                arch=product_arch() if kind == 'swiftpm' else 'universal',
                **({'workspace': str(ROOT.resolve())} if kind == 'swiftpm' else {}))


CPU_TYPES = {0x01000007: 'x86_64', 0x0100000c: 'arm64'}


def product_arch():
    """The architecture of this job's SwiftPM products. A rented Apple Silicon Mac builds and
    runs the x86_64 products too, so the job names it (CASSINI_CI_ARCH), not the machine."""
    name = os.environ.get('CASSINI_CI_ARCH') or os.uname().machine
    if name not in CPU_TYPES.values():
        raise ValueError('Unsupported product architecture: ' + name)
    return name


def macho_arch(path):
    """The architecture of a thin little-endian 64-bit Mach-O file, 'universal' for a fat one,
    'unknown' for any other Mach-O (32-bit, big-endian, another CPU), None for other files."""
    with Path(path).open('rb') as stream:
        header = stream.read(8)
    if len(header) < 8:
        return None
    if header[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        return 'universal'
    if header[:4] in (b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf'):
        return 'unknown'
    if header[:4] != b'\xcf\xfa\xed\xfe':
        return None
    return CPU_TYPES.get(int.from_bytes(header[4:8], 'little'), 'unknown')


def check_swiftpm_arch(expected):
    """Every executable and test bundle the consumers run has exactly the named architecture,
    and the test bundle `swift test --skip-build` loads is really there: a layout this check
    does not know must fail, not pass with nothing inspected."""
    folder = ROOT/'.build/debug'
    if not folder.is_dir():
        raise ValueError('No SwiftPM products at .build/debug')
    files = [path for path in folder.iterdir() if path.is_file() and not path.is_symlink()]
    bundles = [path for path in folder.glob('*.xctest/Contents/MacOS/*') if path.is_file()]
    for path in sorted(files + bundles):
        found = macho_arch(path)
        if found is not None and found != expected:
            raise ValueError('Product %s is %s, not %s' % (path.relative_to(ROOT), found, expected))
    if not any(macho_arch(path) == expected for path in bundles):
        raise ValueError('No %s test bundle among the SwiftPM products' % expected)


RELEASE_SDK_OBJECTS = ('CassiniSpectrogram', 'CassiniRecording', 'CassiniBrowserControl', 'CassiniLibrary', 'CassiniKit')


def check_release_arch():
    """Verify both runnable slices, including the SDK objects consumed by the native probe.

    A fat header alone is insufficient: it can contain just one architecture. Ask lipo for
    the actual slices of every Mach-O (frameworks and dSYMs included) and static library.
    """
    folder = ROOT/'build/Build/Products/Release'
    required = {folder/'Cassini.app/Contents/MacOS/Cassini'} | {folder/(name+'.o') for name in RELEASE_SDK_OBJECTS}
    for path in sorted(required):
        if not path.is_file():
            raise ValueError('Missing Release binary: ' + str(path.relative_to(ROOT)))
    magic = {bytes.fromhex(value) for value in (
        'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
        'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    inspected = set()
    for path in sorted(folder.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            header = stream.read(8)
        binary = header[:4] in magic or header == b'!<arch>\n'
        if not binary and path.suffix not in ('.o', '.dylib', '.a', '.so'):
            continue
        slices = set(subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).split())
        missing = {'arm64', 'x86_64'} - slices
        if missing:
            raise ValueError('Release binary %s missing required slices: %s (found %s)' % (
                path.relative_to(ROOT), ', '.join(sorted(missing)), ', '.join(sorted(slices))))
        inspected.add(path)
    if required - inspected:
        raise ValueError('Required Release executable/SDK object was not inspected: ' +
                         ', '.join(str(path.relative_to(ROOT)) for path in sorted(required - inspected)))


# Release tooling that once lived in SwiftPM's .build (release.py now keeps it in build/). A
# restored .build cache can still hold it, so the swiftpm product never ships it: a venv's
# interpreter link is absolute, which unpack rightly refuses. Named directories only; every
# other member, links included, is packed and checked as before.
TOOL_STATE = re.compile(r'^\.build/(dmg-tools-[^/]+|dmg-pip-cache)(/|$)')


def tool_state(item):
    """A member of one of those directories, or the directory itself (never a same-named file)."""
    match = TOOL_STATE.match(item.name)
    return match is not None and (match.group(2) == '/' or item.isdir())


def pack(kind, destination):
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (kind + '.tar.gz')
    paths = PRODUCTS[kind]
    if kind == 'debug':
        paths = ['build/Build/Products/Debug'] + [str(p.relative_to(ROOT)) for p in (ROOT/'build/Build/Products').glob('*.xctestrun')]
        if len(paths) < 2:
            raise ValueError('Missing build-for-testing test specification')
    if kind == 'swiftpm':
        check_swiftpm_arch(product_arch())
    elif kind == 'release':
        check_release_arch()
    with tarfile.open(archive, 'w:gz', compresslevel=1, dereference=False) as target:
        for name in paths:
            if not (ROOT/name).exists():
                raise ValueError('Missing product: ' + name)
            target.add(ROOT/name, arcname=name, filter=lambda item: None if tool_state(item) else item)
    metadata = identity(kind)
    metadata['sha256'] = digest(archive)
    (destination/(kind+'.json')).write_text(json.dumps(metadata, indent=2)+'\n')


class TransferError(ValueError):
    """A download that arrived incomplete (missing or truncated archive): fetching it again can
    help. Every other product mismatch (revision, architecture, Xcode, pins, unsafe members) is
    a plain ValueError and is never retried (D66 rule 2)."""


class WorkspaceMismatch(ValueError):
    """Verified SwiftPM bytes compiled for another absolute checkout path."""


TRANSFER_EXIT = 75  # EX_TEMPFAIL: the action downloads that product once more


def unpack(kind, source):
    if not (source/(kind+'.json')).is_file() or not (source/(kind+'.tar.gz')).is_file():
        raise TransferError('Product download missing: '+kind)
    metadata = json.loads((source/(kind+'.json')).read_text())
    expected = identity(kind)
    if any(metadata.get(key) != value for key, value in expected.items() if key != 'workspace'):
        raise ValueError('Product revision, architecture, Xcode or pins do not match checkout')
    archive = source/(kind+'.tar.gz')
    if digest(archive) != metadata['sha256']:
        raise TransferError('Product archive digest mismatch')
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
        if kind == 'swiftpm':
            workspace = metadata.get('workspace')
            if not isinstance(workspace, str) or not Path(workspace).is_absolute():
                raise ValueError('Missing or invalid SwiftPM workspace identity')
            if workspace != expected['workspace']:
                raise WorkspaceMismatch('SwiftPM workspace differs: ' + workspace + ' -> ' + expected['workspace'])
        packed.extractall(ROOT, members=members)
    if kind == 'swiftpm':
        check_swiftpm_arch(expected['arch'])
    elif kind == 'release':
        check_release_arch()
    print('Restored verified', kind, 'products for', expected['commit'])


def restore(kind, source):
    """Reuse only path-compatible objects; otherwise compile this checkout.

    Source, toolchain, pins, digest and archive safety are still checked first.
    This is not a retry of a failed test/build or a re-download. SwiftPM embeds
    absolute paths in Bundle.module and #filePath, so a relocated consumer must
    generate its own objects before any --skip-build test can run.
    """
    try:
        unpack(kind, source)
    except WorkspaceMismatch as error:
        print(str(error) + '; building test products in this checkout', flush=True)
        # The job's architecture, not the machine's: a rented Mac cross-compiles x86_64 products.
        subprocess.run(['swift', 'build', '--build-tests', '--arch', product_arch()], cwd=ROOT, check=True)
        check_swiftpm_arch(product_arch())


def stage_assets(kind, destination):
    """Only the producer uses this opt-in path; shipped code never uses CI state."""
    source = Path(os.environ['CASSINI_CI_ASSETS'])/kind
    hashes = json.loads((source/'unsigned-sha256.json').read_text())
    if kind == 'Opus' and json.loads((source/'pins.json').read_text()) != json.loads((ROOT/'Opus/pins.json').read_text()):
        raise ValueError('Opus pin mismatch')
    if kind == 'Parakeet':
        if json.loads((source/'pins.json').read_text()) != json.loads((ROOT/'Parakeet/pins.json').read_text()):
            raise ValueError('Parakeet pin mismatch')
        for name, expected in json.loads((ROOT/'Parakeet/UPSTREAM.json').read_text())['sha256'].items():
            if digest(ROOT/name) != expected: raise ValueError('Parakeet header/notice pin mismatch')
            if name.startswith('Parakeet/') and digest(source/Path(name).name) != expected:
                raise ValueError('Staged Parakeet metadata mismatch: '+name)
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
    parser.add_argument('action', choices=['pack', 'unpack', 'restore', 'stage-assets'])
    parser.add_argument('kind', choices=list(PRODUCTS)+['Whistle', 'Opus', 'Parakeet'])
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    if args.action == 'stage-assets':
        stage_assets(args.kind, args.directory)
    elif args.action == 'pack':
        pack(args.kind, args.directory)
    else:
        try:
            (restore if args.action == 'restore' else unpack)(args.kind, args.directory)
        except TransferError as error:
            print(error, file=sys.stderr); sys.exit(TRANSFER_EXIT)


if __name__ == '__main__':
    main()
