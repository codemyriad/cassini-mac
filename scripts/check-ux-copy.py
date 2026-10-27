#!/usr/bin/env python3
import hashlib,json,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
folder=root/'Cassini/Resources/UX'
pin=json.loads((folder/'UPSTREAM.json').read_text())
raw=(folder/'strings.json').read_bytes()
assert hashlib.sha256(raw).hexdigest()==pin['sha256']
entries={e['id']:e for e in json.loads(raw)['entries']}
# D7 Q5 explicitly requires this published line for reserve-stop behavior.
# Catalog v5 still labels its later UX6 milestone pending. Keep the shared bytes
# verbatim, and limit this exception to the exact message selected by D7.
decision_approved={'errors.diskStopped.line'}
for file in (root/'Cassini').rglob('*.swift'):
    for key in re.findall(r'UXText\.text\("([^"]+)"',file.read_text()):
        assert key in entries and (entries[key]['status']!='pending' or key in decision_approved), (file,key)
        assert 'mac' in entries[key]['platforms'], (file,key)
print('Shared catalog hash and every used Mac string id verified')
