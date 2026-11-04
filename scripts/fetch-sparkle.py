#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetch pinned build/release tools; never called by the installed app."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile
import urllib.request

VERSION = '2.10.1'
SHA256 = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'

def fetch(destination):
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / ('Sparkle-' + VERSION + '.tar.xz')
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        temporary = archive.with_suffix('.download')
        try:
            urllib.request.urlretrieve('https://github.com/sparkle-project/Sparkle/releases/download/' + VERSION + '/' + archive.name, temporary)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
                raise ValueError('Sparkle distribution digest mismatch')
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    # Validate members and links before the system tar restores framework symlinks.
    with tarfile.open(archive) as packed:
        for entry in packed:
            path = Path(entry.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('Unsafe Sparkle archive path')
            if entry.issym() or entry.islnk():
                resolved = (destination/path.parent/entry.linkname).resolve()
                if not resolved.is_relative_to(destination.resolve()):
                    raise ValueError('Unsafe Sparkle archive link')
            elif not (entry.isfile() or entry.isdir()):
                raise ValueError('Unsupported Sparkle archive member')
    output = destination / 'distribution'
    output.mkdir(exist_ok=True)
    subprocess.run(['tar', '-xf', str(archive), '-C', str(output)], check=True)
    return output

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.build/Sparkle'))
    print(fetch(parser.parse_args().output))
