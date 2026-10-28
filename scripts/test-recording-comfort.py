#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Device-free, opt-in real app probe; no desktop capture/automation required."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
hosted = os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1', 'Explicit hosted/local workflow opt-in required'
environment = dict(os.environ, CASSINI_HOSTED_SCREENSHOTS='1')
command = [str(args.app.resolve()/'Contents/MacOS/Cassini'), '--recording-comfort-self-test',
           '--fixture-library-recording', '-CassiniCaptureID', str(uuid.uuid4()), '-CassiniSilentMicrophone', 'YES',
           '-CassiniDiskFree', str(20 << 30), '-CassiniDiskTotal', str(100 << 30)]
args.output.mkdir(parents=True, exist_ok=True)
try:
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=45)
except subprocess.TimeoutExpired as error:
    def decoded(value):
        return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value or ''
    (args.output/'recording-comfort-stderr.txt').write_text(decoded(error.stderr))
    (args.output/'recording-comfort-stdout.txt').write_text(decoded(error.stdout))
    raise
(args.output/'recording-comfort-stderr.txt').write_text(result.stderr)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
report = json.loads(result.stdout)
for name in ('recordingComfort', 'sameNameCaptureIsolation', 'shortcutRegistered', 'noteTimesPreserved', 'titleReset', 'browserClockAndSources', 'diskWarningLifecycle', 'silentMicAfter20Seconds', 'assertionReleasedAfterStop'):
    assert report[name] is True, (name, report)
menu = report['menu']
assert menu['assertionHeld'] is True and menu['levels'][0]['silent'] is True
assert [action['id'] for action in menu['actions']] == ['stop', 'note', 'open']
assert menu['actions'][0]['shortcut'] == '⌥⌘R'
(args.output/'recording-comfort.json').write_text(json.dumps(report, indent=2)+'\n')
(args.output/'recording-menu.json').write_text(json.dumps(menu, indent=2)+'\n')
print('PASS real RAM capture, title/notes, 20-second silence, global registration, IOPM lease and Stop/Saving')
