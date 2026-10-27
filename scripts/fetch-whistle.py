#!/usr/bin/env python3
"""Build-time only: verify pinned wheels/weights and assemble both Mac slices."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''): value.update(block)
        return value.hexdigest()


def checked(path, expected):
    if digest(path) != expected:
        raise ValueError('SHA256 mismatch: ' + path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    output = args.output; output.mkdir(parents=True, exist_ok=True)
    cache = args.cache or output.parent / 'whistle-downloads'
    cache.mkdir(parents=True, exist_ok=True)
    pins = json.loads((ROOT / 'Whistle/pins.json').read_text())
    slices = []
    for artifact in pins['artifacts']:
        archive = cache / artifact['name']
        if archive.exists():
            checked(archive, artifact['sha256'])  # Fail on corrupt cache, never trust it.
        else:
            pending = archive.with_suffix(archive.suffix + '.part')
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(artifact['url'], timeout=60) as source, pending.open('wb') as target:
                        shutil.copyfileobj(source, target)
                    break
                except OSError:
                    pending.unlink(missing_ok=True)
                    if attempt == 2: raise
                    time.sleep(attempt + 1)
            checked(pending, artifact['sha256']); pending.replace(archive)
        if 'member' in artifact:
            target = cache / ('libneedle3-' + artifact['arch'] + '.dylib')
            with zipfile.ZipFile(archive) as wheel:
                target.write_bytes(wheel.read(artifact['member']))
            checked(target, artifact['memberSha256']); slices.append(target)
        else:
            shutil.copyfile(archive, output / artifact['name'])
    library = output / 'libneedle3.dylib'
    subprocess.run(['xcrun', 'lipo', '-create', *map(str, slices), '-output', str(library)], check=True)
    architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(library)], text=True).split()
    if set(architectures) != {'arm64', 'x86_64'}: raise ValueError('Universal engine slices missing')
    checked(ROOT / 'Whistle/LICENSE', pins['licenseSha256'])
    for name in ['LICENSE', 'NOTICE', 'pins.json']:
        shutil.copyfile(ROOT / 'Whistle' / name, output / name)
    (output / 'unsigned-sha256.json').write_text(json.dumps({p.name: digest(p) for p in output.iterdir() if p.name in ['whistle.cact', 'libneedle3.dylib']}, indent=2) + '\n')
    print('Verified Whistle weights and needle 3.3.0: arm64 + x86_64')


if __name__ == '__main__':
    main()
