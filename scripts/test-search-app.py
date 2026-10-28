#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run real app FTS/filter/navigation checks over its bundled public fixture."""
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
app = args.app.resolve()
result = subprocess.run([str(app/'Contents/MacOS/Cassini'),'--search-self-test','-CassiniScreenshot','library',
                         '-CassiniFixture',str(app/'Contents/Resources/Fixtures/Library/main'),
                         '-CassiniNow','2026-10-27T13:18:00Z','-ApplePersistenceIgnoreState','YES'],
                        env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=45)
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.with_suffix('.stderr.txt').write_text(result.stderr)
assert result.returncode == 0,(result.returncode,result.stdout,result.stderr)
report = json.loads(result.stdout)
assert report['places'] == 4 and report['meetings'] == 3 and report['d14Order'] == [4000,872000,1870000,527000]
assert all(report[name] is True for name in ('realAppFTS5','andFilters','filtersResetOnClose','navigationClosesSearch','selectAllPreserved'))
assert report['hitSeekMs'] == 872000 and report['audioDevicesOpened'] is False
args.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS real app FTS5, shared4/3 fixture, D14 filters/order, hit seek and close reset (no playback)')
