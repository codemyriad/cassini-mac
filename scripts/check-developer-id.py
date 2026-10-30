#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspect every shipped Mach-O without executing it."""
from pathlib import Path
import plistlib
import json
import re
import subprocess
import sys

MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}

def inspect(app):
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    catalog = json.loads((app/'Contents/Resources/UX/strings.json').read_text())
    name = next(entry['en'] for entry in catalog['entries'] if entry['id'] == 'app.name')
    assert name == 'Cassini talk', 'Unexpected public product name'
    assert all(info[key] == name for key in ['CFBundleName', 'CFBundleDisplayName']), 'Bundle name differs from catalog'
    assert info['CFBundleIdentifier'] == 'io.codemyriad.cassini', 'Unexpected product identity'
    count = 0
    for file in sorted(app.rglob('*')):
        if file.is_symlink() or not file.is_file():
            continue
        with file.open('rb') as stream:
            if stream.read(4) not in MAGIC:
                continue
        count += 1
        result = subprocess.run(['codesign','-d','--verbose=4',str(file)],check=True,capture_output=True,text=True).stderr
        assert 'Authority=Developer ID Application: Codemyriad OU (4LS8W738Y3)' in result, (file,'Developer ID authority')
        assert 'TeamIdentifier=4LS8W738Y3' in result, (file,'wrong team')
        assert re.search(r'flags=0x[0-9a-f]+\([^)]*\bruntime\b',result), (file,'runtime missing')
        assert re.search(r'^Timestamp=.+',result,re.M), (file,'secure timestamp missing')
        raw = subprocess.run(['codesign','-d','--entitlements',':-',str(file)],check=True,capture_output=True).stdout
        profile = plistlib.loads(raw) if raw.strip() else {}
        assert not profile.get('com.apple.security.get-task-allow'), (file,'debug entitlement')
        assert not profile.get('com.apple.security.cs.disable-library-validation'), (file,'library validation disabled')
        archs = subprocess.check_output(['lipo','-archs',str(file)],text=True).split()
        assert {'arm64','x86_64'}.issubset(archs), (file,'not universal',archs)
    assert count >= 8, 'Missing nested executables'
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    print('PASS Developer ID, secure timestamp, hardened runtime and universal architecture on',count,'Mach-O files')

if __name__ == '__main__':
    inspect(Path(sys.argv[1]))
