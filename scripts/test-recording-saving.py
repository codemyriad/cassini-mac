#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private app clock/metadata proof, with no document windows, recording inputs or hotkeys."""
import argparse,json,os,subprocess,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('app',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
assert os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS')=='1' or (os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'),'Explicit workflow opt-in required'
command=[str(a.app.resolve()/'Contents/MacOS/Cassini'),'--recording-saving-self-test','-CassiniCaptureID',str(uuid.uuid4()),'-ApplePersistenceIgnoreState','YES']
r=subprocess.run(command,env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=15)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.with_suffix('.stderr.txt').write_text(r.stderr)
assert r.returncode==0,(r.returncode,r.stdout,r.stderr)
report=json.loads(r.stdout)
for key in ['recordingClockAdvances','savingUsesProducerEnd','lifecycleOnlySavingHolds']:assert report[key] is True,report
assert report['audioDevicesOpened'] is False and report['documentWindowsOpened'] is False,report
a.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS signed app: Saving uses the producer end, freezes on reopen')
