#!/usr/bin/env python3
import hashlib,json,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
folder=root/'Cassini/Resources/UX'
pin=json.loads((folder/'UPSTREAM.json').read_text())
raw=(folder/'strings.json').read_bytes()
assert hashlib.sha256(raw).hexdigest()==pin['sha256']
assert (root/'Sources/CassiniLibrary/Localization/strings.json').read_bytes() == raw
import_pin=json.loads((folder/'import-types-UPSTREAM.json').read_text())
import_raw=(folder/'import-types.json').read_bytes()
assert import_pin['repository']=='cassini-ux' and import_pin['path']=='contract/import-types.json'
assert hashlib.sha256(import_raw).hexdigest()==import_pin['sha256']
assert (root/'Sources/CassiniLibrary/Schema/import-types.json').read_bytes() == import_raw
entries={e['id']:e for e in json.loads(raw)['entries']}
mac_entries={e['id']:e for e in json.loads((root/'Sources/CassiniLibrary/Localization/mac.json').read_text())['entries']}
# D7 Q5 explicitly requires this published line for reserve-stop behavior.
# Catalog v5 still labels its later UX6 milestone pending. Keep the shared bytes
# verbatim, and limit this exception to the exact message selected by D7.
decision_approved={'errors.diskStopped.line'}
# D22 explicitly gives the Mac Why dialog one common.close button. The catalog
# still tags that older common entry GNOME-only; keep its published bytes.
# D58.1 (coordinator, #140 review): Mac shows the shared GNOME line when the system tap could
# not be started (not a permission denial), with no settings action.
platform_decision_approved={'common.close','errors.deviceUnavailable.others'}
for file in (root/'Cassini').rglob('*.swift'):
    for key in re.findall(r'UXText\.text\("([^"]+)"',file.read_text()):
        assert key in entries and (entries[key]['status']!='pending' or key in decision_approved), (file,key)
        assert 'mac' in entries[key]['platforms'] or key in platform_decision_approved, (file,key)
for file in (root/'Cassini').rglob('*.swift'):
    for key in re.findall(r'UXText\.mac\("([^"]+)"',file.read_text()):
        assert 'mac.'+key in mac_entries,(file,key)
print('Shared catalog hash and every used Mac string id verified')
