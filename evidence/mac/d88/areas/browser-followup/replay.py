from pathlib import Path
import difflib
import json
import os
import signal
import subprocess
import tempfile

root=Path(__file__).resolve().parents[5]
BASE='89c568bca3528417a74888720f0379103273138d'
BASE=subprocess.check_output(['git','rev-parse',BASE],cwd=root,text=True).strip()
evidence=Path(os.environ['D88_EVIDENCE_DIR']).resolve(); evidence.mkdir(parents=True,exist_ok=True)
resume=os.environ.get('CASSINI_NEXT_IPC_SCRATCH')
scratch=Path(resume) if resume else Path(tempfile.mkdtemp(prefix='d88-next-ipc-'))
(evidence/'scratch.txt').write_text(str(scratch)+'\n')
if not resume:
    archive=subprocess.check_output(['git','archive',BASE],cwd=root)
    subprocess.run(['tar','-xf','-','-C',str(scratch)],input=archive,check=True)
patch=subprocess.check_output(['git','diff',BASE,'--','Tests/CassiniBrowserControlTests/ControlServiceTests.swift','Tests/CassiniBrowserControlTests/D52HeartbeatTests.swift','Tests/CassiniBrowserControlTests/HeldStartTests.swift'],cwd=root)
suite='ControlServiceTests|D52HeartbeatTests|HeldStartTests'
def run(name,test,expected):
    path=evidence/f'{name}.log'
    with path.open('w') as stream:
        # Compilation and test execution have separate failure-only hang bounds.
        # A slow compiler cannot count as the intended mutation assertion.
        for command,bound in [(['swift','build','--build-tests','--scratch-path',str(scratch/'build'),'--jobs','4'],180),
                              (['swift','test','--skip-build','--scratch-path',str(scratch/'build'),'--filter',test],45)]:
            child=subprocess.Popen(command,cwd=scratch,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
            try: code=child.wait(timeout=bound)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL); child.wait()
                raise RuntimeError(f'{name} exceeded its build/test hang bound')
            if command[1]=='build': assert code==0,(name,'compilation',path)
    text=path.read_text()
    if expected:
        assert code==0,(name,path)
    else:
        assertion='XCTAssertNil failed' if name=='lost-peer-eof' else 'XCTAssertEqual failed'
        assert code!=0 and assertion in text and 'Asynchronous wait failed' not in text,(name,path)
    print(name,code,flush=True)

frame='Sources/CassiniBrowserControl/FrameIO.swift'
control='Sources/CassiniBrowserControl/ControlService.swift'
old='guard let header = try exact(fd,count:4,cancel:cancel,deadline:deadline,alive:alive,clock:clock,progress:progress) else { return nil }'
# The injected EOF fault reports a timeout instead of a closed stream.
frame_source=(scratch/frame).read_text()
if old not in frame_source:
    matches=[line for line in frame_source.splitlines() if 'guard let header = try exact(' in line]
    assert len(matches)==1,matches
    old=matches[0].strip()
    assert old.endswith('else { return nil }'),old
new=old.replace('else { return nil }','else { throw BrowserIPCError.timeout }')
if not resume:
    run('before',suite,True)
    (scratch/frame).write_text(frame_source.replace(old,new))
    run('before-timeout-mutant','testPingsOverTheRealPipeAndSilenceLosesControl',True)
    (scratch/frame).write_text(frame_source)
    subprocess.run(['git','apply','-'],cwd=scratch,input=patch,check=True)
else:
    for name in ('ControlServiceTests.swift','D52HeartbeatTests.swift','HeldStartTests.swift'):
        path='Tests/CassiniBrowserControlTests/'+name
        (scratch/path).write_bytes((root/path).read_bytes())
run('after',suite,True)
cases=[
 ('stale-peer-output','testFreshStopWithAStaleUIKeyUsesTheCurrentCaptureConnection','pong','command'),
 ('reconnect-stop-output','testDisconnectedCaptureStopSurvivesARealPipeReconnectAndNewURLCanStart','pong','command'),
 ('audio-stop-all-output','testRegisteredAudioThenDisconnectedStopAllBeforeAnyCaptureStatusCannotRestart','pong','command'),
 ('held-start-output','testTheServiceCompletesALostStartOnceWhenTheRestartedLinkReportsTheCapture','pong','command'),
 ('legacy-initial-output','testALegacyHelloIsNeverPingedOrTimedOut','empty-inventory','ping'),
 ('legacy-frame-output','testALegacyHelloIsNeverPingedOrTimedOut','nonempty-inventory','ping'),
 ('lost-peer-eof','testPingsOverTheRealPipeAndSilenceLosesControl','eof','timeout'),
]
results=[]
for name,test,trigger,message in cases:
    path=frame if trigger=='eof' else control
    original=(scratch/path).read_text()
    if trigger=='eof':
        mutated=original.replace(old,new)
    else:
        needle='            received(message["type"]?.string)'
        assert original.count(needle)==1
        if trigger=='pong':
            condition='message["type"]?.string == "pong"'
        else:
            compare='==' if trigger=='empty-inventory' else '>'
            condition=f'message["type"]?.string == "meetings" && clock() {compare} 1_000_000'
        payload='{"type":"command","action":"start","tabId":2}' if message=='command' else '{"type":"ping","seq":999}'
        swift_string=payload.replace('"','\\"')
        injected=f'            if {condition} {{ try connection.send(Data("{swift_string}".utf8)) }}\n'
        mutated=original.replace(needle,injected+needle)
    assert original!=mutated
    (evidence/f'{name}.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True),mutated.splitlines(keepends=True),'a/'+path,'b/'+path,n=0)))
    (scratch/path).write_text(mutated)
    try: run(name,test,False)
    finally: (scratch/path).write_text(original)
    results.append({'case':name,'test':test,'mutation':'failed'})
run('restored',suite,True)
(evidence/'results.json').write_text(json.dumps({'base':BASE,'scratch':str(scratch),'cases':results},indent=2)+'\n')
