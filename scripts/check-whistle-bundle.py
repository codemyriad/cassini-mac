#!/usr/bin/env python3
"""Inspect a signed build without launching it or loading the engine."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
resources = app/'Contents/Resources/Whistle'
worker = app/'Contents/MacOS/cassini-whistle-worker'
library = app/'Contents/Frameworks/libneedle3.dylib'
for obsolete in [resources/'libneedle3.dylib', app/'Contents/Resources/cassini-whistle-worker', app/'Contents/Resources/cassini-browser-host']:
    assert not obsolete.exists(), 'Obsolete code in Resources: '+str(obsolete)
pins = json.loads((resources/'pins.json').read_text())
shipped = json.loads((resources/'bundle-sha256.json').read_text())
vadlibrary = app/'Contents/Frameworks/libonnxruntime.1.23.2.dylib'
for path in [resources/'whistle.cact', resources/'silero_vad.onnx', library, vadlibrary, worker]:
    assert hashlib.sha256(path.read_bytes()).hexdigest() == shipped[path.name], path.name
model = next(a for a in pins['artifacts'] if a['name'] == 'whistle.cact')
assert shipped['whistle.cact'] == model['sha256']
assert shipped['silero_vad.onnx'] == '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3'
for name in ['LICENSE','NOTICE','Silero-LICENSE','ONNXRuntime-LICENSE','ONNXRuntime-ThirdPartyNotices.txt']:
    assert (resources/name).is_file(), name
assert hashlib.sha256((resources/'LICENSE').read_bytes()).hexdigest() == pins['licenseSha256']
architectures = subprocess.check_output(['xcrun','lipo','-archs',str(library)],text=True).split()
assert set(architectures) == {'arm64','x86_64'}, architectures
assert set(subprocess.check_output(['xcrun','lipo','-archs',str(vadlibrary)],text=True).split()) == {'arm64','x86_64'}
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Whistle bundle: source pins, shipped checksums, universal engine and signatures verified')
