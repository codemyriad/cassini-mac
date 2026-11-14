#!/usr/bin/env python3
"""Vendor shared copy/import contracts verbatim from a local cassini-ux checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkout', type=Path)
parser.add_argument('--ref', default='origin/main')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
commit = subprocess.check_output(['git', '-C', str(args.checkout), 'rev-parse', args.ref], text=True).strip()
for source, destinations, pin in [
    ('strings/strings.json', ['Cassini/Resources/UX/strings.json', 'Sources/CassiniLibrary/Localization/strings.json'], 'UPSTREAM.json'),
    ('contract/import-types.json', ['Cassini/Resources/UX/import-types.json', 'Sources/CassiniLibrary/Schema/import-types.json'], 'import-types-UPSTREAM.json'),
]:
    raw = subprocess.check_output(['git', '-C', str(args.checkout), 'show', f'{commit}:{source}'])
    json.loads(raw)
    for destination in destinations:
        (root / destination).write_bytes(raw)
    (root / 'Cassini/Resources/UX' / pin).write_text(json.dumps({
        'repository': 'cassini-ux', 'path': source, 'commit': commit,
        'sha256': hashlib.sha256(raw).hexdigest(),
    }, indent=2) + '\n')
subprocess.run(['python3', str(root / 'scripts/check-ux-copy.py')], check=True)
print(f'Vendored cassini-ux {commit}')
