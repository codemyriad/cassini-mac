#!/usr/bin/env python3
"""Compare actual Mac observations against the pinned pure reader's `when`."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

PIN = '32f37a6200c88bdd4d23c1f44497f1761f3401da'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('reference', type=Path)
p.add_argument('inspector', type=Path)
p.add_argument('--extra-cases', type=Path)
a = p.parse_args()
assert subprocess.check_output(['git', '-C', str(a.reference), 'rev-parse', 'HEAD'], text=True).strip() == PIN
script = a.reference / 'tools/cassini-read-pure.py'
subprocess.run(['git', '-C', str(a.reference), 'diff', '--exit-code', 'HEAD', '--', str(script)], check=True)
spec = importlib.util.spec_from_file_location('reference_when', script)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
root = Path(__file__).resolve().parents[3]
files = sorted((root / 'Tests/CassiniKitTests/Conformance/opus').glob('*.opus'))
if a.extra_cases:
    files += sorted(a.extra_cases.glob('*.opus'))
results = []
for file in files:
    reference, _ = reader.read_file(str(file))
    when = reference.get('when', (None, None))
    expected = {'source': when[0], 'value': when[1]} if when[0] else None
    actual = json.loads(subprocess.check_output([str(a.inspector.resolve()), '--metadata', str(file)], text=True))
    assert actual['meetingStart'] == expected, (file.name, expected, actual['meetingStart'])
    results.append({'case': file.name, 'when': expected, 'result': 'match'})
print(json.dumps({'referencePin': PIN, 'cases': results}, indent=2))
