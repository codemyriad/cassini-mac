from pathlib import Path
import os,subprocess,shutil,signal,json
home=Path.home();heads=json.loads((home/'AWS-MAC-ROUTING-HEADS.json').read_text());base=Path('/tmp/cassini-aws-d88-before');archive=Path('/tmp/cassini-aws-d88-handoff/evidence/mac/d88/aws-handoff-2026-11-10');out=archive/'routing-merge-validation';out.mkdir(exist_ok=True)
rows=[(210,Path('/Users/ec2-user/agents/cassini-mac'),'ControlServiceTests'),(211,Path('/tmp/cassini-aws-d88-browser'),'AudioBrokerTests|InputLifecycleTests|D52SourceOutcomeTests'),(212,Path('/tmp/cassini-aws-d88-playback'),'SessionPlaybackTests'),(213,Path('/tmp/cassini-aws-d88-setup'),'InstallationTests|BackgroundSetupTests|LibraryWatcherTests'),(214,Path('/tmp/cassini-aws-d88-model'),'ModelDownloaderTests'),(215,Path('/tmp/cassini-aws-d88-transport'),'PipeTransportTests|ControlHostTests|FrameIOTests|TranscriptionMeetingTests.testSidecarWriteObserverReadsCommittedBytesForGeneratedSilence')]
results=[]
for n,root,selected in rows:
 head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip();assert head==heads[str(n)]
 paths=subprocess.check_output(['git','diff','main','--name-only','HEAD'],cwd=root,text=True).splitlines();paths=[p for p in paths if p.startswith(('Sources/','Tests/')) or p in ('Package.swift','Package.resolved')]
 originals={p:(base/p).read_bytes() if (base/p).is_file() else None for p in paths}
 try:
  for p in paths:
   dst=base/p;src=root/p
   if src.is_file():dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dst)
   elif dst.exists():dst.unlink()
  env=dict(os.environ)
  if n==215:env.update(CASSINI_PIPELINE_ASSETS=str(home/'work/cassini-mac/build/Whistle'),NEEDLE_TELEMETRY='0',DO_NOT_TRACK='1',ORT_DISABLE_TELEMETRY='1')
  with (out/f'{n}.log').open('w') as log:
   p=subprocess.Popen(['swift','test','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4','--filter',selected+'|ModelSupersessionTests'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   try:rc=p.wait(timeout=300)
   except BaseException:os.killpg(p.pid,signal.SIGKILL);p.wait();raise
  results.append(dict(pr=n,head=head,filter=selected+'|ModelSupersessionTests',exit=rc));(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(n,head,'PASS' if rc==0 else 'FAIL',flush=True)
  if rc:raise RuntimeError('Local validation failed '+str(n))
 finally:
  for path,data in originals.items():
   dst=base/path
   if data is None:
    if dst.exists():dst.unlink()
   else:dst.write_bytes(data)
