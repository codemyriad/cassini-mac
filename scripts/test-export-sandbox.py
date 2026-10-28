#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the opt-in sealed app probe with generated audio and private files."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',type=Path)
parser.add_argument('--output',type=Path,required=True)
args = parser.parse_args()
hosted = os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1', 'Explicit workflow opt-in required'
result = subprocess.run([str(args.app.resolve()/'Contents/MacOS/Cassini'),'--export-self-test'],
                        env=dict(os.environ,CASSINI_HOSTED_EXPORT='1'),capture_output=True,text=True,timeout=45)
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.with_suffix('.stderr.txt').write_text(result.stderr)
assert result.returncode == 0,(result.returncode,result.stdout,result.stderr)
report = json.loads(result.stdout)
assert set(report) == {'sealedBundledOpus','sandboxExport','emptyWordsReadyToWriteDown','notesRoundTrip','opusDigestPreserved'}
assert all(value is True for value in report.values()),report
args.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS sealed sandbox app: PCM export, save, import, notes and packet-preserving re-export')
