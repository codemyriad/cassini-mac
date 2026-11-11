"""D88 real-state mutations, applied from the committed patches in private scratch."""
from pathlib import Path
import json
import os
import re
import signal
import subprocess
import tempfile

root = Path(__file__).resolve().parents[5]
proof = Path(__file__).resolve().parent
BASE = '89c568bca3528417a74888720f0379103273138d'
REVIEWED = '4b5feff15aa3d4ab61e006d5dbda83604ccbf1d7'
evidence = Path(os.environ['D88_EVIDENCE_DIR']).resolve()
assert root not in (evidence, *evidence.parents), 'Evidence must be outside the checkout'
evidence.mkdir(parents=True, exist_ok=True)
resume = os.environ.get('CASSINI_NEXT_IPC_SCRATCH')
scratch = Path(resume) if resume else Path(tempfile.mkdtemp(prefix='d88-next-ipc-'))
(evidence/'scratch.txt').write_text(str(scratch)+'\n')
if not resume:
    archive = subprocess.check_output(['git','archive',BASE],cwd=root)
    subprocess.run(['tar','-xf','-','-C',str(scratch)],input=archive,check=True)
tests = ['Tests/CassiniBrowserControlTests/'+name for name in
         ('ControlServiceTests.swift','D52HeartbeatTests.swift','HeldStartTests.swift')]
production = ['Sources/CassiniBrowserControl/'+name for name in
              ('ControlRegistry.swift','ControlHeartbeat.swift','FrameIO.swift')]
for file in tests + production:
    (scratch/file).write_bytes(subprocess.check_output(['git','show',BASE+':'+file],cwd=root))
suite = 'ControlServiceTests|D52HeartbeatTests|HeldStartTests'
def run(name, test, assertion=None):
    path = evidence/(name+'.log')
    with path.open('w') as stream:
        for command,bound in [(['swift','build','--build-tests','--scratch-path',str(scratch/'build'),'--jobs','4'],180),
                              (['swift','test','--skip-build','--scratch-path',str(scratch/'build'),'--filter',test],45)]:
            child = subprocess.Popen(command,cwd=scratch,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
            try: code = child.wait(timeout=bound)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL); child.wait()
                raise RuntimeError(name+' exceeded its build/test hang bound')
            if command[1]=='build': assert code==0,(name,'compilation',path)
    text = path.read_text()
    assert re.search(r"Executed [1-9][0-9]* tests?",text),(name,"no XCTest executed",path)
    if assertion:
        assert code!=0 and assertion in text and 'Asynchronous wait failed' not in text,(name,path)
        failures = [line for line in text.splitlines() if assertion in line]
    else:
        assert code==0,(name,path)
        failures = []
    print(name,code,flush=True)
    return failures

def apply(name, reverse=False):
    command = ['git','apply','--unidiff-zero'] + (['--reverse'] if reverse else []) + [str(proof/(name+'.patch'))]
    subprocess.run(command,cwd=scratch,check=True)

run('before',suite)
apply('lost-peer-eof')
try: run('before-timeout-mutant','testPingsOverTheRealPipeAndSilenceLosesControl')
finally: apply('lost-peer-eof',reverse=True)
for file in tests: (scratch/file).write_bytes((root/file).read_bytes())
run('after',suite)
# The reviewed test never ticked after later frames. This real state mutation
# passes that test, then fails the corrected test's ordered Stop assertion.
legacy = scratch/tests[1]
corrected = legacy.read_bytes()
legacy.write_bytes(subprocess.check_output(['git','show',REVIEWED+':'+tests[1]],cwd=root))
apply('legacy-status-renegotiation')
try: run('reviewed-legacy-status-mutant','testALegacyHelloIsNeverPingedOrTimedOut')
finally:
    apply('legacy-status-renegotiation',reverse=True)
    legacy.write_bytes(corrected)
cases = [
 ('stale-peer-output','testFreshStopWithAStaleUIKeyUsesTheCurrentCaptureConnection','XCTAssertEqual failed'),
 ('reconnect-stop-output','testDisconnectedCaptureStopSurvivesARealPipeReconnectAndNewURLCanStart','XCTAssertEqual failed'),
 ('audio-stop-all-output','testRegisteredAudioThenDisconnectedStopAllBeforeAnyCaptureStatusCannotRestart','XCTAssertEqual failed'),
 ('held-start-output','testTheServiceCompletesALostStartOnceWhenTheRestartedLinkReportsTheCapture','XCTAssertEqual failed'),
 ('legacy-initial-output','testALegacyHelloIsNeverPingedOrTimedOut','XCTAssertNotNil failed'),
 ('legacy-frame-output','testALegacyHelloIsNeverPingedOrTimedOut','XCTAssertNotNil failed'),
 ('legacy-status-renegotiation','testALegacyHelloIsNeverPingedOrTimedOut','XCTAssertEqual failed'),
 ('lost-peer-eof','testPingsOverTheRealPipeAndSilenceLosesControl','XCTAssertNil failed'),
]
results = []
for name,test,assertion in cases:
    apply(name)
    try: failures = run(name,test,assertion)
    finally: apply(name,reverse=True)
    results.append({'case':name,'test':test,'mutation':'behavioral assertion failure','assertions':failures})
run('restored',suite)
for file in production:
    assert (scratch/file).read_bytes()==(root/file).read_bytes(),file
(evidence/'results.json').write_text(json.dumps({'base':BASE,'reviewed':REVIEWED,'scratch':str(scratch),'cases':results},indent=2)+'\n')
