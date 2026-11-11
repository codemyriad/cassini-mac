#!/usr/bin/env python3
"""Run the actual sandboxed D96 coordinator with private generated files only."""
import argparse,json,os,subprocess,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('app',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
hosted=os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS')=='1','Explicit workflow opt-in required'
if not hosted:
    assert os.stat('/dev/console').st_uid == os.getuid(), 'Run this app proof in the console user’s Aqua session'
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        worker=subprocess.run(['pgrep','-u',str(os.getuid()),'-x','Runner[.]Worker'],capture_output=True)
        assert worker.returncode==1, 'The GUI runner is busy; wait for its queued job to finish before a manual proof'

key=str(uuid.uuid4())
a.output.parent.mkdir(parents=True,exist_ok=True)
try:
    run=subprocess.run([str(a.app.resolve()/'Contents/MacOS/Cassini'),'--bulk-transfer-self-test','--fixture-library-recording',
 '-CassiniCaptureID',key,'-CassiniSettingsID',key,'-AppleLanguages','(en)','-ApplePersistenceIgnoreState','YES'],
 env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=90)
except subprocess.TimeoutExpired as error:
    stderr=error.stderr or b''
    if isinstance(stderr,bytes): stderr=stderr.decode(errors='replace')
    a.output.with_suffix('.stderr.txt').write_text(stderr)
    raise
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.with_suffix('.stderr.txt').write_text(run.stderr)
assert run.returncode==0,(run.returncode,run.stdout,run.stderr)
report=json.loads(run.stdout)
assert all(report[k] for k in ['multipleImport','zipImport','ordinaryDedup','storedAllExport','selectedExport','originalAudioBytes','queuedCancellation','staleSaveChoiceRejected','localizedSummary'])
assert report['audioDevicesOpened'] is False
a.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS sandboxed bulk import/dedup, all/selected stored export, original audio and queued cancellation')
