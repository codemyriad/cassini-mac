from pathlib import Path
import subprocess,shutil,sys,difflib
base=Path('/tmp/cassini-aws-d88-before');root=Path('/tmp/cassini-aws-d88-transport');out=root/'evidence/mac/d88/aws-transport';out.mkdir(parents=True,exist_ok=True)
selected='CassiniBrowserControlTests|TranscriptionMeetingTests'
def run(label,selected=selected):
    with (out/(label+'.log')).open('w') as log:
        result=subprocess.call(['swift','test','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4','--filter',selected],stdout=log,stderr=subprocess.STDOUT)
    print(label,result,flush=True);return result
if run('before'):sys.exit(1)
paths=subprocess.check_output(['git','diff','--name-only'],cwd=root,text=True).splitlines()
originals={p:(base/p).read_bytes() for p in paths}
try:
    for p in paths:shutil.copyfile(root/p,base/p)
    if run('after'):sys.exit(1)
    path='Sources/CassiniBrowserControl/PipeTransport.swift';target=base/path;original=target.read_text();modified=original.replace('FrameIO.read(input,cancel:cancellation,alive:', 'FrameIO.read(input,cancel:cancellation,deadline:readClock()+250_000_000,alive:')
    assert original!=modified
    target.write_text(modified)
    (out/'partial-deadline.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True),modified.splitlines(True),fromfile='a/'+path,tofile='b/'+path)))
    try:
        if run('partial-deadline','PipeTransportTests.testSlowFragmentedPeerDoesNotBlockAnotherOrLoseItsPartialFrame')==0:raise RuntimeError('Mutation survived')
    finally:target.write_text(original)
    if run('restored'):sys.exit(1)
finally:
    for p,data in originals.items():(base/p).write_bytes(data)
