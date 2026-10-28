#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import json
from pathlib import Path
import shutil
import struct
import sys
source, target = map(Path, sys.argv[1:])
target.mkdir(parents=True, exist_ok=True)
manifest = json.loads((source/'manifest.json').read_text())
for name in ('library', 'first-run', 'meeting', 'record-first', 'recording', 'received', 'export'):
    matches = [a for test in manifest for a in test['attachments'] if a['suggestedHumanReadableName'].startswith(name + '_') or a['suggestedHumanReadableName'] == name+'.png']
    assert len(matches) == 1, (name, matches)
    path = source/matches[0]['exportedFileName']
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24]) == (1120,720)
    shutil.copyfile(path,target/(name+'.png'))
    print(name, '1120x720')
payloads = [a for test in manifest for a in test['attachments'] if a['suggestedHumanReadableName'].startswith('recording-menu')]
assert len(payloads) == 1, payloads
payload = source/payloads[0]['exportedFileName']
value = json.loads(payload.read_text())
assert value['assertionHeld'] is True and [a['id'] for a in value['actions']] == ['stop','note','open']
shutil.copyfile(payload,target/'recording-menu.json')
