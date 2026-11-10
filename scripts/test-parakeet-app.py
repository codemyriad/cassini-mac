#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real signed app queue proof, using private streamed model files and bundled JFK."""
import argparse,json,os,plistlib,subprocess,threading,uuid
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('app',type=Path);p.add_argument('--model',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
a=p.parse_args()
assert os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS')=='1' or (os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'),'Explicit workflow opt-in required'
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
signed=subprocess.run(['codesign','-d','--entitlements',':-',str(a.app)],capture_output=True,check=True)
profile=plistlib.loads(signed.stdout)
expected=plistlib.loads((Path(__file__).resolve().parent.parent/'Cassini/Cassini.entitlements').read_bytes())
assert profile==expected and not profile.get('com.apple.security.network.client'),'Use the exact product sandbox profile'
key=str(uuid.uuid4());a.report.parent.mkdir(parents=True,exist_ok=True)
command=[str(a.app.resolve()/'Contents/MacOS/Cassini'),'--parakeet-self-test',
         '-CassiniSettingsID',key,'-CassiniCaptureID',key,'-CassiniSpeechMemoryBytes',str(8 << 30),'-ApplePersistenceIgnoreState','YES']
with a.report.with_suffix('.stderr.txt').open('w') as errors:
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,
                           env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'))
    failures=[]
    def send():
        try:
            for name in sorted(['encoder.int8.onnx','decoder.int8.onnx','joiner.int8.onnx','tokens.txt']):
                with (a.model/name).open('rb') as source:
                    while block:=source.read(1<<20):child.stdin.write(block)
        except (OSError,ValueError) as error:failures.append(str(error))
        finally:child.stdin.close()
    sender=threading.Thread(target=send,daemon=True);sender.start()
    try:status=child.wait(timeout=180)
    except subprocess.TimeoutExpired:
        # Preserve the actual hung signed-app PID before cleanup destroys the
        # only evidence (D66 run42580139946, Intel). No deadline extension or
        # retry: sampling is diagnostic work after the original180s failure.
        # Run42676060732 sampled successfully but the old5s diagnostic limit
        # killed symbol processing before it wrote a stack. Wait for sample's
        # completion (30s upper bound), leaving the original failure unchanged.
        try:
            with a.report.with_suffix('.timeout-process.txt').open('w') as diagnostic:
                subprocess.run(['/bin/ps','-p',str(child.pid),'-o','pid=,ppid=,state=,etime=,time=,comm='],
                               stdout=diagnostic,stderr=subprocess.STDOUT,timeout=5)
            with a.report.with_suffix('.sample.log').open('w') as diagnostic:
                subprocess.run(['/usr/bin/sample',str(child.pid),'1','10','-file',
                                str(a.report.with_suffix('.stack.txt'))],
                               stdout=diagnostic,stderr=subprocess.STDOUT,timeout=30)
        except (OSError,subprocess.SubprocessError) as error:
            a.report.with_suffix('.diagnostic-error.txt').write_text(str(error))
        finally:
            child.kill();child.wait()
        raise
    sender.join(timeout=5);output=child.stdout.read();child.stdout.close()
assert status==0,(status,output.decode(errors='replace'),a.report.with_suffix('.stderr.txt').read_text())
assert not failures and not sender.is_alive(),failures
report=json.loads(output)
for name in ['sandboxedBundledParakeet','unverifiedModelCannotBecomeDefault','verifiedInstallationBecomesDefault','legacyIdRetiredOnlyAfterV2Verifies','explicitWhistleChoiceSurvivesRelaunch',
             'firstWhistleSuggestionHonorsCapability','suggestionDismissalPersists','defaultNoticeShownOnce','removePreservesAcceptedJob','queuedJobUsesWhistle',
             'invalidModelRetriesWhistle','invalidModelDeleted','choicePersisted','metadataAndAudioPreserved',
             'unusedDamagedInstallationRecovers','removeMessageFollowsDiskCommit','inventoryPreservesAcceptedModel','emptyTranscriptRetryRequeues',
             'removeLockObserved','acceptedJobHeldDuringRemove','queueCompletionEvents']:
    assert report[name] is True,(name,report)
assert report['parakeetWords']>10 and report['audioDevicesOpened'] is False
a.report.write_text(json.dumps(report,indent=2)+'\n')
print('PASS signed Parakeet queue: active Remove, queued Whistle, pinned corruption fallback and preserved metadata/audio')
