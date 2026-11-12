"""Replay actual production mutations; logs/build products stay outside the checkout."""
from pathlib import Path
import hashlib,json,os,re,subprocess
area=Path(__file__).resolve().parent;root=area.parents[2]
out=Path(os.environ['BROWSER_ME_EVIDENCE']).resolve();out.mkdir(parents=True,exist_ok=True)
assert root not in (out,*out.parents)
assert os.environ.get('CASSINI_OPUS_ASSETS')
build=Path(os.environ.get('BROWSER_ME_BUILD',str(out/'build')))
cases=json.loads((area/'cases.json').read_text())
original={c['source']:(root/c['source']).read_bytes() for c in cases}
base=['swift','test','--scratch-path',str(build),'--jobs','4']
def run(name,test,mutant=False):
 with (out/(name+'.log')).open('w') as log:
  r=subprocess.run(base+['--filter',test],cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 text=(out/(name+'.log')).read_text()
 assert re.search(r'Executed [1-9][0-9]* tests?',text),(name,'no XCTest case executed')
 if mutant:
  assertions=[line for line in text.splitlines() if 'error:' in line and 'XCTAssert' in line and 'failed' in line]
  assert r.returncode!=0 and assertions,(name,'no behavioral assertion failure')
  assert 'Asynchronous wait failed' not in text and 'error: Exited with unexpected signal' not in text,(name,'hang or crash')
  return assertions[0]
 assert r.returncode==0,(name,'failed baseline/restoration')
 return 'passed'
focused='BrowserLocalMeTests|SenderMeNegotiationTests|ControlRegistryTests|D52UnselectedSourceTests|D58ResumeOutcomeTests|R94CommittedResumeTests|InputLifecycleTests/testAnOffOthersSideNeverRestoresOnBrowserReturn'
run('baseline',focused);receipts=[]
for case in cases:
 patch=area/(case['name']+'.patch')
 try:
  subprocess.run(['git','apply','--check',str(patch)],cwd=root,check=True)
  subprocess.run(['git','apply',str(patch)],cwd=root,check=True)
  assertion=run(case['name'],case['test'],True)
  receipts.append(dict(**case,result='behavioral assertion failure',assertion=assertion))
  print(case['name'],'rejected',flush=True)
 finally:
  for source,data in original.items():(root/source).write_bytes(data)
run('restored',focused)
assert all((root/source).read_bytes()==data for source,data in original.items())
(out/'results.json').write_text(json.dumps(dict(mutations=receipts,restored=True,sourceSHA256={s:hashlib.sha256(d).hexdigest() for s,d in original.items()}),indent=2)+'\n')
print('All committed production mutations rejected; restored suite passed',flush=True)
