#!/usr/bin/env python3
"""Compare actual Mac observations against the pinned pure reader's `when`."""
import argparse
import importlib.util
import json
import re
from datetime import datetime
from pathlib import Path
import subprocess

PIN = '32f37a6200c88bdd4d23c1f44497f1761f3401da'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('reference', type=Path)
p.add_argument('inspector', type=Path)
p.add_argument('--extra-cases', type=Path)
p.add_argument('--validate-exports', action='store_true', help='Check exported timestamp fields against the pinned schema patterns and calendar validity')
a = p.parse_args()
assert subprocess.check_output(['git', '-C', str(a.reference), 'rev-parse', 'HEAD'], text=True).strip() == PIN
script = a.reference / 'tools/cassini-read-pure.py'
subprocess.run(['git', '-C', str(a.reference), 'diff', '--exit-code', 'HEAD', '--', str(script), 'spec/cassini-portable-meeting-manifest-v1.schema.json'], check=True)
spec = importlib.util.spec_from_file_location('reference_when', script)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
root = Path(__file__).resolve().parents[3]
files = sorted((root / 'Tests/CassiniKitTests/Conformance/opus').glob('*.opus'))
if a.extra_cases:
    files += sorted(a.extra_cases.glob('*.opus'))
results = []
schema = json.loads((a.reference / 'spec/cassini-portable-meeting-manifest-v1.schema.json').read_text())
timestamp_fields = {key: value for key, value in schema['$defs']['meeting']['properties'].items()
                    if key in ('createdAtUtc', 'recordedAtUtc', 'recordedAtLocal')}
validated_exports = []
for file in files:
    reference, _ = reader.read_file(str(file))
    if a.validate_exports and a.extra_cases and file.parent == a.extra_cases and ('export' in file.stem or file.stem.startswith('fraction-')):
        meeting = reference['manifest']['meeting']
        assert 'createdAtUtc' in meeting, file.name
        for key, rule in timestamp_fields.items():
            if key not in meeting:
                continue
            value = meeting[key]
            assert isinstance(value, str) and re.fullmatch(rule['pattern'], value), (file.name, key, value)
            datetime.strptime(value[:19], '%Y-%m-%dT%H:%M:%S')  # Fields only; Python 3.9 rejects valid four-digit fractions.
        validated_exports.append(file.name)
    when = reference.get('when', (None, None))
    expected = {'source': when[0], 'value': when[1]} if when[0] else None
    actual = json.loads(subprocess.check_output([str(a.inspector.resolve()), '--metadata', str(file)], text=True))
    assert actual['meetingStart'] == expected, (file.name, expected, actual['meetingStart'])
    results.append({'case': file.name, 'when': expected, 'result': 'match'})
if a.validate_exports:
    assert validated_exports, 'No exported files checked'
print(json.dumps({'referencePin': PIN, 'cases': results, 'timestampSchemaCheckedExports': validated_exports}, indent=2))
