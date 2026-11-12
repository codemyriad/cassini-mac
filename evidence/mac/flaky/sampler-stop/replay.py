#!/usr/bin/env python3
"""Apply the committed signal mutation and require an actual exit-code assertion."""
from pathlib import Path
import hashlib,json,os,subprocess,sys
area=Path(__file__).resolve().parent;root=area.parents[3]
out=Path(os.environ['SAMPLER_EVIDENCE']).expanduser().resolve();out.mkdir(parents=True,exist_ok=True)
assert root not in (out,*out.parents)
source=root/'scripts/test-spectrogram-app.py';original=source.read_bytes()
command=[sys.executable,'scripts/test-spectrogram-sampler.py']
def run(name,args):
 with (out/(name+'.log')).open('w') as log:r=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=30)
 return r.returncode,(out/(name+'.log')).read_text()
assert run('baseline',command)[0]==0
try:
 subprocess.run(['git','apply','--check',str(area/'terminate.patch')],cwd=root,check=True)
 subprocess.run(['git','apply',str(area/'terminate.patch')],cwd=root,check=True)
 code,text=run('mutant',command+['SamplerStopTests.test_signal_choice_is_explicit_for_a_cooperative_sampler'])
 assert code!=0 and 'AssertionError: 0 != -9' in text and 'TimeoutExpired' not in text,text
finally:source.write_bytes(original)
assert run('restored',command)[0]==0
assert source.read_bytes()==original
(out/'results.json').write_text(json.dumps({'tests':3,'mutation':'actual child exit0 instead of SIGKILL(-9), assertion failure','restored':True,'sourceSHA256':hashlib.sha256(original).hexdigest()},indent=2)+'\n')
print('Three child-process cases pass; real signal mutation fails the exit-code assertion; restored passes')
