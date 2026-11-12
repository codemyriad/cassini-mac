"""Run under heavy-run in an idle Aqua session; restores production source in finally."""
from pathlib import Path
import difflib,json,subprocess,os,signal
root=Path(__file__).resolve().parents[3]
out=Path(os.environ['D95_FOOTER_EVIDENCE_DIR']).expanduser().resolve()
assert root not in (out,*out.parents),'Use external evidence'
out.mkdir(parents=True,exist_ok=True)
p=root/'Cassini/Library/LibraryView.swift';original=p.read_text()
assert original.count('if updates.readyWhenIdle {')==1
signal.signal(signal.SIGTERM,lambda *_:(_ for _ in ()).throw(KeyboardInterrupt()))
prefix=json.loads(os.environ.get('D95_GUI_PREFIX_JSON','[]'))
def command(cycles):return prefix+['env','D95_UPDATER_CYCLES='+str(cycles),os.sys.executable,str(root/'evidence/mac/d95/footer-mount-probe.py')]
results=[]
try:
 for name,value,assertion in [('always-visible','true','Idle removes the real footer from layout'),('always-absent','false','Busy activity renders the real footer')]:
  mutated=original.replace('if updates.readyWhenIdle {','if '+value+' {')
  p.write_text(mutated)
  (out/(name+'.patch')).write_text(''.join(difflib.unified_diff(original.splitlines(True),mutated.splitlines(True),fromfile='a/Cassini/Library/LibraryView.swift',tofile='b/Cassini/Library/LibraryView.swift',n=1)))
  log=out/(name+'.log')
  with log.open('w') as stream:
   run=subprocess.run(command(1),env=os.environ,stdout=stream,stderr=subprocess.STDOUT,timeout=90)
  text=log.read_text()
  assert run.returncode and 'FAILED: check("'+assertion+'")' in text and 'missing ' not in text,(name,text)
  results.append({'case':name,'failure':assertion,'timeout':False});print(name,'fails layout assertion',flush=True)
  p.write_text(original)
finally:p.write_text(original)
with (out/'restored.log').open('w') as stream:
 subprocess.run(command(40),env=os.environ,stdout=stream,stderr=subprocess.STDOUT,timeout=180,check=True)
(out/'mutations.json').write_text(json.dumps(results,indent=2)+'\n')
print('Restored 40 occluded updater cycles pass',flush=True)
