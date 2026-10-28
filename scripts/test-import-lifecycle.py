#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private generated-file app probe; no real browser or audio devices."""
import argparse,json,os,subprocess,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('app',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
hosted=os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS')=='1','Explicit workflow opt-in required'
r=subprocess.run([str(a.app.resolve()/'Contents/MacOS/Cassini'),'--import-lifecycle-self-test','--fixture-library-recording',
                  '-CassiniCaptureID',str(uuid.uuid4()),'-CassiniTranscriptionFixture','YES','-CassiniSlowTranscription','YES',
                  '-ApplePersistenceIgnoreState','YES'],env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=45)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.with_suffix('.stderr.txt').write_text(r.stderr)
assert r.returncode==0,(r.returncode,r.stdout,r.stderr)
report=json.loads(r.stdout)
assert all(report[k] for k in ['queueMetadataOffMain','metadataBeforeWorker','repeatedWriteDownImportsOnce','shutdownWaitsForImport'])
assert report['audioDevicesOpened'] is False
a.output.write_text(json.dumps(report,indent=2)+'\n');print('PASS queue metadata off-main, owned/coalesced imports and shutdown cleanup')
