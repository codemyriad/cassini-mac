#!/usr/bin/env python3
"""Summarise what CI can observe about SwiftPM products: names, architectures, build versions, signatures."""
import subprocess, sys, json, re
from pathlib import Path
root = Path(sys.argv[1])  # a .build/debug directory
rows = {}
def run(*a):
    r = subprocess.run(a, capture_output=True, text=True); return r.stdout + r.stderr
items = [p for p in sorted(root.iterdir()) if p.is_file() and not p.suffix and (p.stat().st_mode & 0o111)]
items += sorted(root.glob('*.xctest/Contents/MacOS/*')) + sorted(root.glob('*.dylib'))
for p in items:
    archs = run('xcrun', 'lipo', '-archs', str(p)).strip()
    if 'fatal' in archs or "can't" in archs: continue
    build = run('xcrun', 'vtool', '-show-build', str(p))
    minos = re.search(r'minos (\S+)', build); sdk = re.search(r'sdk (\S+)', build); plat = re.search(r'platform (\S+)', build)
    sign = run('codesign', '-dv', str(p))
    ident = re.search(r'^Identifier=(.+)$', sign, re.M); flags = re.search(r'flags=(\S+)', sign); sig = re.search(r'^Signature=(.+)$', sign, re.M)
    rows[str(p.relative_to(root))] = dict(archs=archs, platform=plat and plat.group(1), minos=minos and minos.group(1), sdk=sdk and sdk.group(1),
        identifier=ident and re.sub(r'-[0-9a-f]{40}$', '-<cdhash>', ident.group(1)), flags=flags and flags.group(1), signature=sig and sig.group(1))
bundles = sorted(str(p.relative_to(root)) for p in root.glob('*.bundle')) + sorted(str(p.relative_to(root)) for p in root.glob('*.resources'))
print(json.dumps(dict(machos=rows, resource_bundles=bundles), indent=1, sort_keys=True))
