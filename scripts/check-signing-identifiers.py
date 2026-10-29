#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspect the finished bundle without launching or changing any signed code."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--require-hardened-runtime', action='store_true', help='Also require runtime flags for ad-hoc fixture code')
args = parser.parse_args()
app = args.app
prefix = 'io.codemyriad.cassini'
bundles = {
    '.': '',
    'Contents/PlugIns/CassiniQuickLook.appex': '.quicklook',
    'Contents/XPCServices/CassiniBrowserSetup.xpc': '.browser-setup',
    'Contents/XPCServices/CassiniModelDownloads.xpc': '.models',
}
tools = {
    'cassini-browser-host': '.browser-host',
    'cassini-control-host': '.control-host',
    'cassini-whistle-worker': '.whistle-worker',
    'cassini-parakeet-worker': '.parakeet-worker',
}

def signature(path, expected, require_runtime=False):
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)],
                            check=True, capture_output=True, text=True)
    fields = dict(line.split('=', 1) for line in result.stderr.splitlines() if '=' in line)
    assert fields.get('Identifier') == expected, (path, fields.get('Identifier'), expected)
    flag_match = re.search(r'\bflags=0x[0-9a-fA-F]+\(([^)]*)\)', result.stderr)
    flags = set(flag_match.group(1).split(',')) if flag_match else set()
    if require_runtime:
        assert 'runtime' in flags, (path, 'missing hardened runtime')
    if any(line.startswith('Authority=') for line in result.stderr.splitlines()):
        assert 'runtime' in flags, path
        assert fields.get('Timestamp'), (path, 'missing secure timestamp')
    return fields

for relative, suffix in bundles.items():
    bundle = app / relative
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == prefix + suffix, (bundle, info['CFBundleIdentifier'])
    signature(bundle, prefix + suffix, args.require_hardened_runtime)
for name, suffix in tools.items():
    signature(app / 'Contents/MacOS' / name, prefix + suffix, args.require_hardened_runtime)
# Worker signing is part of the build, before the manifest is written. Signing
# after restoration or packaging would invalidate these exact shipped hashes.
for engine, paths in {
    'Whistle': {'cassini-whistle-worker': 'MacOS', 'libneedle3.dylib': 'Frameworks',
                'libonnxruntime.1.23.2.dylib': 'Frameworks', 'silero_vad.onnx': 'Resources/Whistle',
                'whistle.cact': 'Resources/Whistle'},
    'Parakeet': {'cassini-parakeet-worker': 'MacOS', 'libsherpa-onnx-c-api.dylib': 'Frameworks',
                 'libonnxruntime.dylib': 'Frameworks'},
}.items():
    manifest = json.loads((app / 'Contents/Resources' / engine / 'bundle-sha256.json').read_text())
    for name, parent in paths.items():
        digest = hashlib.sha256()
        with (app / 'Contents' / parent / name).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        assert digest.hexdigest() == manifest[name], (engine, name, 'signed bytes changed')
print('PASS eight io.codemyriad signing identifiers, bundle IDs and final worker hashes')
