#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise Settings and relocation through the real app with private RAM fixtures."""
import argparse,json,os,plistlib,subprocess,uuid
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',type=Path);parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
hosted=os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS')=='1','Explicit workflow opt-in required'
# Direct probes must not inherit XCTest's extra filesystem grants.
signed=subprocess.run(['codesign','-d','--entitlements',':-',str(args.app.resolve())],capture_output=True,check=True)
expected=plistlib.loads((Path(__file__).resolve().parent.parent/'Cassini/Cassini.entitlements').read_bytes())
assert plistlib.loads(signed.stdout)==expected,'Re-sign with Cassini/Cassini.entitlements before running this sandbox proof'
key=str(uuid.uuid4())
command=[str(args.app.resolve()/'Contents/MacOS/Cassini'),'--settings-self-test','--fixture-library-recording',
         '-CassiniCaptureID',key,'-CassiniSettingsID',key,'-CassiniTranscriptionFixture','YES','-CassiniSlowTranscription','YES',
         '-CassiniDiskFree',str(20<<30),'-CassiniDiskTotal',str(100<<30),'-ApplePersistenceIgnoreState','YES']
r=subprocess.run(command,env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=60)
args.output.parent.mkdir(parents=True,exist_ok=True);args.output.with_suffix('.stderr.txt').write_text(r.stderr)
assert r.returncode==0,(r.returncode,r.stdout,r.stderr)
report=json.loads(r.stdout)
for name in ['firstCaptureCreatesLibrary','settingsPreferences','realShortcutReplacement','shortcutConflictRetainsOld','closedMeetingMovedAtomically',
             'partialFailureRetainsOriginal','liveFolderDeferred','pendingMovesPersisted','activeInferencePathPreserved','queuedMetadataMovedAfterPreparation','importIntentResumesAfterMove','retainedSelectionUsesFolder','searchReindexed','hostReadsLocation','producerBytesPreserved']:
    assert report[name] is True,(name,report)
resume=[x for x in command]
resume[resume.index('--settings-self-test')]='--settings-resume-moves-self-test'
resume[resume.index('-CassiniTranscriptionFixture')+1]='NO'
continued=subprocess.run(resume,env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=60)
args.output.with_suffix('.resume-stderr.txt').write_text(continued.stderr)
assert continued.returncode==0,(continued.returncode,continued.stdout,continued.stderr)
resumed=json.loads(continued.stdout)
assert resumed['liveFolderMovedAfterStop'] is True and resumed['pendingMovesResumedAfterRelaunch'] is True and resumed['audioDevicesOpened'] is False
report.update(resumed)
assert report['audioDevicesOpened'] is False
args.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS real Settings/shortcut, private per-meeting move, live/job deferral, persisted move resume and Search rebasing and app/host location')
