from pathlib import Path
import subprocess,shutil,sys,difflib
base=Path('/tmp/cassini-aws-d88-before'); root=Path('/tmp/cassini-aws-d88-model'); out=root/'evidence/mac/d88/aws-model';out.mkdir(parents=True,exist_ok=True)
def run(label,selected='ModelDownloaderTests'):
    with (out/(label+'.log')).open('w') as log:
        result=subprocess.call(['swift','test','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4','--filter',selected],stdout=log,stderr=subprocess.STDOUT)
    print(label,result,flush=True);return result
if run('before'):sys.exit(1)
paths=['Tests/CassiniModelsTests/ModelDownloaderTests.swift','Tests/CassiniModelsTests/Fixtures/server.py']
originals={p:(base/p).read_bytes() for p in paths}
try:
    for p in paths:shutil.copyfile(root/p,base/p)
    if run('after'):sys.exit(1)
    target=base/paths[1]; original=target.read_text(); modified=original.replace("print('startup-held',flush=True)","print('http://127.0.0.1:1',flush=True)")
    target.write_text(modified)
    (out/'false-ready.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True),modified.splitlines(True),fromfile='a/'+paths[1],tofile='b/'+paths[1])))
    try:
        if run('false-ready','ModelDownloaderTests.fixtureBootstrapWithoutAReadinessEventFailsAndReapsItsChild')==0:raise RuntimeError('Mutation survived')
    finally:target.write_text(original)
    if run('restored'):sys.exit(1)
finally:
    for p,data in originals.items():(base/p).write_bytes(data)
