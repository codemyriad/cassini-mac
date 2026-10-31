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
root = Path(__file__).resolve().parent.parent
profiles = {'':'Cassini/Cassini.entitlements','.quicklook':'QuickLook/CassiniQuickLook.entitlements',
    '.browser-setup':'BrowserSetup/BrowserSetup.entitlements','.models':'ModelDownloads/ModelDownloads.entitlements',
    '.whistle-worker':'Whistle/worker.entitlements','.parakeet-worker':'Whistle/worker.entitlements'}
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
    profile_result = subprocess.run(['codesign','-d','--entitlements',':-',str(path)],check=True,capture_output=True)
    actual_profile = plistlib.loads(profile_result.stdout) if profile_result.stdout.strip() else {}
    file = profiles.get(expected.removeprefix(prefix))
    expected_profile = plistlib.loads((root/file).read_bytes()) if file else {}
    if expected.removeprefix(prefix) in ['.browser-host','.control-host']:
        # Xcode can attach this identity even to an otherwise empty tool
        # profile. It grants no sandbox capability; validate it rather than
        # accepting any testing exceptions beside it.
        if 'com.apple.application-identifier' in actual_profile:
            identity = actual_profile.pop('com.apple.application-identifier')
            allowed = {expected}
            team = fields.get('TeamIdentifier')
            if team and team != 'not set':allowed.add(team+'.'+expected)
            assert identity in allowed, (path,'Unexpected native host application identifier',identity)
    assert actual_profile == expected_profile, (path,'Product entitlements differ',actual_profile,expected_profile)
    return fields

for relative, suffix in bundles.items():
    bundle = app / relative
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == prefix + suffix, (bundle, info['CFBundleIdentifier'])
    if relative == '.':
        resources = bundle/'Contents/Resources'
        assert '{{' not in (resources/'Cassini.html').read_text(), 'Unrendered companion page'
        assert info.get('CFBundleIconName') == 'AppIcon', 'AppIcon must be selected in the product Info.plist'
        assert (resources/'Assets.car').stat().st_size > 0, 'Compiled asset catalog missing'
        assert (resources/'AppIcon.icns').read_bytes()[:4] == b'icns', 'Finder/Dock icon missing'
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
print('PASS eight io.codemyriad signing identifiers, exact product profiles, bundle IDs and final worker hashes')
