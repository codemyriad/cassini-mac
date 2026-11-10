from pathlib import Path
import os,subprocess,shutil,difflib,sys
base=Path('/tmp/cassini-aws-d88-before');root=Path('/tmp/cassini-aws-d88-transport');out=root/'evidence/mac/d88/aws-transport'
paths=subprocess.check_output(['git','diff','main','--name-only','HEAD'],cwd=root,text=True).splitlines()
paths=list(dict.fromkeys(p for p in paths if p.endswith('.swift')))
originals={p:(base/p).read_bytes() for p in paths}
env=dict(os.environ,CASSINI_PIPELINE_ASSETS=str(Path.home()/'work/cassini-mac/build/Whistle'),NEEDLE_TELEMETRY='0',DO_NOT_TRACK='1',ORT_DISABLE_TELEMETRY='1')
def run(label,selected):
 with (out/(label+'.log')).open('w') as log:
  rc=subprocess.call(['swift','test','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4','--filter',selected],env=env,stdout=log,stderr=subprocess.STDOUT)
 print(label,rc,flush=True);return rc
selected='TranscriptionMeetingTests.testSidecarWriteObserverReadsCommittedBytesForGeneratedSilence'
try:
 for p in paths:shutil.copyfile(root/p,base/p)
 if run('sidecar-after',selected):sys.exit(1)
 target=base/'Sources/CassiniTranscription/MeetingTranscriber.swift';original=target.read_text();modified=original.replace('try atomicTranscript(data, directory: directory); wroteSidecar = true; sidecarWritten()', 'sidecarWritten(); try atomicTranscript(data, directory: directory); wroteSidecar = true')
 assert modified!=original
 target.write_text(modified)
 (out/'sidecar-before-write.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True),modified.splitlines(True),fromfile='a/Sources/CassiniTranscription/MeetingTranscriber.swift',tofile='b/Sources/CassiniTranscription/MeetingTranscriber.swift')))
 try:
  if run('sidecar-before-write',selected)==0:raise RuntimeError('Mutation survived')
 finally:target.write_text(original)
 if run('sidecar-restored','PipeTransportTests|ControlHostTests|FrameIOTests|'+selected):sys.exit(1)
finally:
 for p,data in originals.items():(base/p).write_bytes(data)
