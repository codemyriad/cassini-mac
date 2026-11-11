#!/usr/bin/env python3
"""Rebuild the actual app for both native publication mutants, then restore it."""
import difflib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
out = Path(os.environ['D96_EVIDENCE_DIR']).expanduser().resolve()
assert root not in (out, *out.parents), 'Use external evidence'
out.mkdir(parents=True, exist_ok=True)
app = Path(os.environ['D96_NATIVE_APP']).expanduser().resolve()
build = json.loads(os.environ['D96_BUILD_COMMAND_JSON'])
prefix = json.loads(os.environ.get('D96_GUI_PREFIX_JSON', '[]'))
proof_output = os.environ.get('D96_PROOF_OUTPUT', str(out / 'native-report.json'))
probe = prefix + [sys.executable, str(root / 'scripts/test-bulk-transfer-app.py'), str(app), '--output', proof_output]
source = root / 'Cassini/Library/LibraryBulkTransfer.swift'
original = source.read_text()
results = []
interrupted = False
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))


def build_app(name):
    with (out / (name + '-build.log')).open('w') as log:
        subprocess.run(build, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)


def check_app(name, positive):
    log = out / (name + '.log')
    with log.open('w') as stream:
        result = subprocess.run(probe, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
    if positive:
        assert result.returncode == 0, name
    else:
        text = log.read_text()
        assert result.returncode != 0 and 'Bulk transfer proof failed' in text, name
        assert 'TimeoutExpired' not in text, name


try:
    for name, old, new in [
        ('queued-cancel', 'task?.cancel(); if task == nil', 'if task == nil'),
        ('stale-save', 'guard generation == epoch else {return}', 'guard true else {return}'),
    ]:
        assert original.count(old) == 1, name
        mutant = original.replace(old, new)
        patch = ''.join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True),
                                           fromfile='a/Cassini/Library/LibraryBulkTransfer.swift',
                                           tofile='b/Cassini/Library/LibraryBulkTransfer.swift', n=0))
        (out / ('native-' + name + '.patch')).write_text(patch)
        source.write_text(mutant)
        build_app('mutation-native-' + name)
        check_app('mutation-native-' + name, False)
        results.append({'case': name, 'result': 'sandbox publication assertion fails without a timeout'})
        source.write_text(original)
        print(name, 'failed as required', flush=True)
except KeyboardInterrupt:
    interrupted = True
    raise
finally:
    source.write_text(original)
    if not interrupted:
        build_app('native-restored')
        check_app('native-restored', True)
    else:
        print('Source restored; rebuild the private native product before using it.', flush=True)
(out / 'native-guard-mutations.json').write_text(json.dumps(results, indent=2) + '\n')
