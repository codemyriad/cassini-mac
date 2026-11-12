#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Replay production regressions using temporary fixtures, never the installer."""
from pathlib import Path
import hashlib
import json
import os
import re
import tempfile
import subprocess
import sys

area = Path(__file__).resolve().parent
root = area.parents[2]
output = Path(os.environ['MAC_SLOT_EVIDENCE']).expanduser().resolve()
assert root not in (output, *output.parents), 'Keep output outside the checkout'
output.mkdir(parents=True, exist_ok=True)
cases = json.loads((area / 'cases.json').read_text())
original = {case['source']: (root / case['source']).read_bytes() for case in cases}
command = [sys.executable, 'scripts/test-daily-test-release.py']

def run(name, args):
    # Same-second/same-size mutations must never reuse a previous .pyc.
    with tempfile.TemporaryDirectory(prefix=name+'-bytecode-', dir=output) as cache:
        result = subprocess.run([args[0], '-X', 'pycache_prefix='+cache, *args[1:]],
                                cwd=root, capture_output=True, text=True, timeout=60)
    log = result.stdout + result.stderr
    (output / (name + '.log')).write_text(log)
    return result.returncode, log

code, baseline = run('baseline', command)
assert code == 0, baseline
count = int(re.search(r'Ran (\d+) tests', baseline).group(1))
results = {}
try:
    for case in cases:
        patch = str(area / (case['name'] + '.patch'))
        subprocess.run(['git', 'apply', '--check', patch], cwd=root, check=True)
        subprocess.run(['git', 'apply', patch], cwd=root, check=True)
        code, log = run(case['name'], command + [case['test']])
        assert code != 0 and 'AssertionError' in log and 'FAILED (failures=' in log and 'ERROR:' not in log, log
        results[case['name']] = 'behavioral assertion failure'
        for name, data in original.items(): (root / name).write_bytes(data)
finally:
    for name, data in original.items(): (root / name).write_bytes(data)
code, restored = run('restored', command)
assert code == 0 and int(re.search(r'Ran (\d+) tests', restored).group(1)) == count, restored
assert all((root / name).read_bytes() == data for name, data in original.items())
(output / 'results.json').write_text(json.dumps({
    'tests': count, 'mutations': results, 'restored': True,
    'sourceSHA256': {name: hashlib.sha256(data).hexdigest() for name, data in original.items()}
}, indent=2) + '\n')
print(f'Seven production regressions fail assertions; all {count} restored policy tests pass')
