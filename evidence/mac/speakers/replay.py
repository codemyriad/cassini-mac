"""Apply committed production mutations and restore in finally; run under heavy-run."""
from pathlib import Path
import hashlib,json,os,re,subprocess
area=Path(__file__).resolve().parent
root=area.parents[2]
out=Path(os.environ['SPEAKER_EVIDENCE_DIR']).resolve()
assert root not in (out,*out.parents),'Evidence belongs outside the checkout'
out.mkdir(parents=True,exist_ok=True)
assert os.environ.get('CASSINI_OPUS_ASSETS'),'Use verified Opus assets'
build=Path(os.environ.get('SPEAKER_BUILD',str(out/'build')))
cases=json.loads((area/'cases.json').read_text())
original={c['source']:(root/c['source']).read_bytes() for c in cases}
base=['swift','test','--scratch-path',str(build),'--jobs','4']
def run(name,test,mutant=False):
 log=out/(name+'.log')
 with log.open('w') as stream:
  result=subprocess.run(base+['--filter',test,'--skip','recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication'],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=600)
 text=log.read_text()
 assert re.search(r'Test run with [1-9][0-9]* tests?',text),(name,'no tests executed')
 if mutant:
  failures=[l for l in text.splitlines() if 'recorded an issue' in l and 'Expectation failed' in l]
  assert result.returncode!=0 and failures,(name,log)
  assert 'Asynchronous wait failed' not in text and 'CONTINUATION MISUSE' not in text,(name,'timeout')
  print(name,'assertion failed',flush=True)
  return failures[0]
 assert result.returncode==0,(name,log)
 print(name,'passed',flush=True)
focused='SpeakerEditsTests|D70SpeakerMergesTests|SessionPlaybackTests|editorCommandsReachMarkdownPortableFileAndReimport|realSpeakerEditsRefreshNamesFiltersAndMergedHits'
run('baseline',focused)
results=[]
for case in cases:
 patch=area/(case['name']+'.patch')
 subprocess.run(['git','apply','--unidiff-zero',str(patch)],cwd=root,check=True)
 try: failure=run(case['name'],case['test'],True)
 finally:
  (root/case['source']).write_bytes(original[case['source']])
 results.append({**case,'result':'behavioral assertion failure','example':failure})
run('restored','CassiniLibraryTests|CassiniSearchTests|CassiniExportTests|SessionPlaybackTests')
for file,data in original.items():assert (root/file).read_bytes()==data,file
(out/'mutations.json').write_text(json.dumps({'cases':results,'sourceSHA256':{f:hashlib.sha256(data).hexdigest() for f,data in original.items()}},indent=2)+'\n')
