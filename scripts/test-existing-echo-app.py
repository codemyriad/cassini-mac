#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted product-app proof over private saved words, PCM and generated inputs."""
import argparse,json,os,plistlib,shutil,subprocess,uuid
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',type=Path);parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted','Disposable hosted Mac required'
app=args.app.resolve()
actual=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True)
expected=plistlib.loads((Path(__file__).resolve().parent.parent/'Cassini/Cassini.entitlements').read_bytes())
assert plistlib.loads(actual.stdout)==expected,'Exact product profile required'
key=str(uuid.uuid4())
command=[str(app/'Contents/MacOS/Cassini'),'--existing-echo-self-test','--fixture-library-recording','-CassiniCaptureID',key,
         '-CassiniTranscriptionFixture','NO','-CassiniDiskFree',str(20<<30),'-CassiniDiskTotal',str(100<<30),'-ApplePersistenceIgnoreState','YES']
result=subprocess.run(command,env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=60)
args.output.parent.mkdir(parents=True,exist_ok=True);args.output.with_suffix('.stderr.txt').write_text(result.stderr)
assert result.returncode==0,(result.returncode,result.stdout,result.stderr)
report=json.loads(result.stdout)
for name in ['captureAdmissionGuardsPublication','automaticBackgroundClassification','recordingPreemptsClassification','idleClassificationResumes','metadataAndAudioPreserved','idempotentMarker','noInferenceModel']:
    assert report[name] is True,(name,report)
assert report['audioDevicesOpened'] is False
root=Path(report.pop('cleanupPath'))
container=(Path.home()/'Library/Containers/io.codemyriad.cassini/Data/tmp').resolve()
assert root.is_absolute() and not root.is_symlink() and root.parent.resolve()==container and root.name=='CassiniLibrary-'+key and root.stat().st_uid==os.getuid(),root
shutil.rmtree(root)
args.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS existing transcript classification: no models/devices, recording preemption, idle resume, unchanged sources and idempotency')
