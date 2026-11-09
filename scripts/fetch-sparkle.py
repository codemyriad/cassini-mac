#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetch pinned build/release tools; never called by the installed app."""
import argparse
import hashlib
import os
import re
import shutil
import urllib.error
import tempfile
from pathlib import Path
import subprocess
import tarfile
import urllib.request

DOWNLOAD_TIMEOUT = 60  # Bound stalled connects and socket reads.
VERSION = '2.10.1'
SPM_SHA256 = '4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a'
SPM_ASSET_API = 'https://api.github.com/repos/sparkle-project/Sparkle/releases/assets/673946482'
SPM_URL = 'https://github.com/sparkle-project/Sparkle/releases/download/' + VERSION + '/Sparkle-for-Swift-Package-Manager.zip'
SHA256 = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'

def _download(url, destination):
    with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as source, destination.open('wb') as output:
        shutil.copyfileobj(source, output)

def fetch(destination):
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / ('Sparkle-' + VERSION + '.tar.xz')
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        temporary = archive.with_suffix('.download')
        try:
            _download('https://github.com/sparkle-project/Sparkle/releases/download/' + VERSION + '/' + archive.name, temporary)
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

def fetch_spm(destination, cache):
    """Preseed SwiftPM's URL-keyed ZIP cache, with the upstream manifest's digest.

    SwiftPM 6.1's download retry can collide with its own partial destination.
    Download outside that cache, verify, then publish atomically. Xcode retains
    its normal remote package pin and verifies the manifest checksum again.
    """
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / 'Sparkle-for-Swift-Package-Manager.zip'
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != SPM_SHA256:
        fd, name = tempfile.mkstemp(prefix='.sparkle-spm-', dir=destination)
        os.close(fd)
        temporary = Path(name)
        try:
            try:
                _download(SPM_URL, temporary)
            except urllib.error.HTTPError as error:
                if not 500 <= error.code < 600:
                    raise
                # The release URL can return a gateway error. Fetch the same
                # immutable asset through GitHub's API, still checking the pin.
                request = urllib.request.Request(SPM_ASSET_API, headers={'Accept': 'application/octet-stream'})
                _download(request, temporary)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != SPM_SHA256:
                raise ValueError('Sparkle SPM digest mismatch')
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    # SwiftPM BinaryArtifactsManager uses spm_mangledToC99ExtendedIdentifier.
    target = cache / re.sub(r'[^a-zA-Z0-9_]', '_', SPM_URL)
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == SPM_SHA256:
        return target
    fd, name = tempfile.mkstemp(prefix='.sparkle-spm-', dir=cache)
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(archive.read_bytes())
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.build/Sparkle'))
    parser.add_argument('--spm-cache', type=Path, help='Preseed this SwiftPM artifacts cache instead of fetching release tools')
    args = parser.parse_args()
    print(fetch_spm(args.output, args.spm_cache) if args.spm_cache else fetch(args.output))
