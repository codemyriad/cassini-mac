#!/usr/bin/env python3
"""Replay only in a disposable worktree: source is temporarily mutated and restored."""
from pathlib import Path
import subprocess,os,json
root=Path(__file__).resolve().parents[4];ev=Path(os.environ['CASSINI_FLAKY_EVIDENCE']).expanduser().resolve();ev.mkdir(parents=True,exist_ok=True)
os.environ['SDKROOT']=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
base=['swift','test','--scratch-path',str(ev/'build'),'--jobs','4']
def run(name,test,fail=False):
 with (ev/(name+'.log')).open('w') as log:r=subprocess.run(base+['--filter',test],cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 s=(ev/(name+'.log')).read_text()
 if fail:
  issues=[l for l in s.splitlines() if 'recorded an issue' in l]
  assert r.returncode!=0 and issues and ('Issue recorded' in s or 'Expectation failed' in s)
  assert 'Asynchronous wait failed' not in s
  print(name,issues[0],flush=True);return issues
 assert r.returncode==0 and 'Test run with' in s;print(name,'passed',flush=True)
test=root/'Tests/CassiniWhistleTests/IOTests.swift';fixed=test.read_bytes()
baseline=subprocess.check_output(['git','show','fc2ad769445f92c0b484eb760a3556dc60f746ac:Tests/CassiniWhistleTests/IOTests.swift'],cwd=root,text=True)
old='let pipe = Pipe(); try pipe.fileHandleForReading.close()'
assert baseline.count(old)==1
baseline=baseline.replace(old,'let pipe = Pipe()\n        let inherited=dup(pipe.fileHandleForReading.fileDescriptor)\n        try #require(inherited>=0);defer {close(inherited)}\n        try pipe.fileHandleForReading.close()')
try:
 test.write_text(baseline);before=run('before-retained-reader','brokenPipeBecomesAnErrorWithoutASignal',True)
finally:test.write_bytes(fixed)
run('after-output','shutDownOutputBecomesAnErrorWithoutASignal')
source=root/'Sources/CassiniWhistle/WhistleIO.swift';original=source.read_bytes()
old='if count < 0 { if errno == EINTR { continue }; throw Failure.system("write", errno) }'
new='if count < 0 { if errno == EPIPE { return }; if errno == EINTR { continue }; throw Failure.system("write", errno) }'
assert original.decode().count(old)==1
try:
 source.write_text(original.decode().replace(old,new));mutation=run('mutation-discard-epipe','shutDownOutputBecomesAnErrorWithoutASignal',True)
finally:source.write_bytes(original)
run('restored','CassiniWhistleTests|ModelDownloaderTests|ModelSupersessionTests')
with (ev/'worker-event-tests.log').open('w') as log:subprocess.run(['python3','scripts/test-whistle-worker-events.py'],cwd=root,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
print('worker event harness passed',flush=True)
(ev/'pipe-proof.json').write_text(json.dumps({'baselineIssues':before,'mutationIssues':mutation,'restored':'passed'},indent=2)+'\n')
