#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspect the pinned, signed D16 runtime without loading it or any optional model."""
import argparse,hashlib,json,plistlib,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('app',type=Path);p.add_argument('--native-only',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parent.parent
resources=a.app/'Contents/Resources/Parakeet';frameworks=a.app/'Contents/Frameworks'
source=json.loads((root/'Parakeet/UPSTREAM.json').read_text())
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
for name,sha in source['sha256'].items():
    if name.startswith('Parakeet/'):
        assert digest(resources/Path(name).name)==sha,name
assert json.loads((resources/'pins.json').read_text())==json.loads((root/'Parakeet/pins.json').read_text())
shipped=json.loads((resources/'bundle-sha256.json').read_text())
worker=a.app/'Contents/MacOS/cassini-parakeet-worker'
for path in [worker,frameworks/'libsherpa-onnx-c-api.dylib',frameworks/'libonnxruntime.dylib']:
    assert digest(path)==shipped[path.name],path
    architectures=set(subprocess.check_output(['xcrun','lipo','-archs',str(path)],text=True).split())
    expected_architectures = {'arm64','x86_64'} if not a.native_only else {subprocess.check_output(['uname','-m'],text=True).strip()}
    assert (architectures == expected_architectures if not a.native_only else expected_architectures <= architectures),architectures
for name in ['encoder.int8.onnx','decoder.int8.onnx','joiner.int8.onnx','tokens.txt']:
    assert not list(a.app.rglob(name)),'Optional model was bundled: '+name
def entitlements(path):
    return plistlib.loads(subprocess.run(['codesign','-d','--entitlements',':-',str(path)],capture_output=True,check=True).stdout)
parent=entitlements(a.app)
assert parent==plistlib.loads((root/'Cassini/Cassini.entitlements').read_bytes())
assert parent['com.apple.security.app-sandbox'] and not parent.get('com.apple.security.network.client')
assert entitlements(worker)==plistlib.loads((root/'Whistle/worker.entitlements').read_bytes())
service=a.app/'Contents/XPCServices/CassiniModelDownloads.xpc'
profile=entitlements(service)
assert profile==plistlib.loads((root/'ModelDownloads/ModelDownloads.entitlements').read_bytes())
assert profile['com.apple.security.app-sandbox'] and profile['com.apple.security.network.client'] and not profile.get('com.apple.security.inherit')
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
print('PASS signed D16 runtime, pinned metadata/notices, isolated download service and no bundled optional weights')
