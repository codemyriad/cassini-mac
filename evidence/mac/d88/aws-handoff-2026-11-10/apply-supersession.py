from pathlib import Path
import os,subprocess,shutil,sys,signal,json
base=Path('/tmp/cassini-aws-d88-before');proof=Path('/tmp/cassini-aws-d88-supersession');fixture='Tests/CassiniModelsTests/ModelSupersessionTests.swift'
rows=[(210,Path('/Users/ec2-user/agents/cassini-mac'),'ControlServiceTests'),(211,Path('/tmp/cassini-aws-d88-browser'),'AudioBrokerTests|InputLifecycleTests|D52SourceOutcomeTests'),(212,Path('/tmp/cassini-aws-d88-playback'),'SessionPlaybackTests'),(213,Path('/tmp/cassini-aws-d88-setup'),'InstallationTests|BackgroundSetupTests|LibraryWatcherTests'),(214,Path('/tmp/cassini-aws-d88-model'),'ModelDownloaderTests'),(215,Path('/tmp/cassini-aws-d88-transport'),'PipeTransportTests|ControlHostTests|FrameIOTests|TranscriptionMeetingTests.testSidecarWriteObserverReadsCommittedBytesForGeneratedSilence')]
files=['README.md','pool-probe.swift','verify.py','before-held-pool.log','after-held-pool.log','after-model-supersession.log','skip-revalidation.patch','skip-revalidation.log','restored.log']
for number,root,selected in rows:
 state=json.loads(subprocess.check_output(['gh','pr','view',str(number),'--json','isDraft,headRefOid'],cwd=root,text=True))
 if not state['isDraft']:raise RuntimeError('Refusing to change ready PR '+str(number))
 if subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip():raise RuntimeError('Unexpected dirty worktree '+str(root))
 shutil.copyfile(proof/fixture,root/fixture)
 out=root/'evidence/mac/d88/aws-supersession';out.mkdir(parents=True,exist_ok=True)
 for f in files:shutil.copyfile(proof/'evidence/mac/d88/aws-supersession'/f,out/f)
 readme=out/'README.md';readme.write_text(readme.read_text()+'\nComplete setup/loader/probe history is preserved on the standalone proof branch at `6ed212b` (`test/d88-aws-supersession-events`). This PR carries the final evidence and its own row-local run.\n')
 paths=subprocess.check_output(['git','diff','main','--name-only','HEAD'],cwd=root,text=True).splitlines()
 paths=list(dict.fromkeys([p for p in paths if p.startswith(('Sources/','Tests/'))]+[fixture]))
 originals={p:(base/p).read_bytes() for p in paths}
 try:
  for p in paths:shutil.copyfile(root/p,base/p)
  env=dict(os.environ)
  if number==215:env.update(CASSINI_PIPELINE_ASSETS=str(Path.home()/'work/cassini-mac/build/Whistle'),NEEDLE_TELEMETRY='0',DO_NOT_TRACK='1',ORT_DISABLE_TELEMETRY='1')
  with (out/'row-local.log').open('w') as log:
   p=subprocess.Popen(['swift','test','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4','--filter',selected+'|ModelSupersessionTests'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   try:rc=p.wait(timeout=300)
   except BaseException:
    os.killpg(p.pid,signal.SIGKILL);p.wait();raise
  print(number,'local',rc,flush=True)
  if rc:raise RuntimeError('Local validation failed for '+str(number))
 finally:
  for path,data in originals.items():(base/path).write_bytes(data)
 subprocess.check_call(['git','diff','--check'],cwd=root)
 subprocess.check_call(['git','add',fixture,'evidence/mac/d88/aws-supersession'],cwd=root)
 subprocess.check_call(['git','commit','-m','test: isolate shared model replacement fixture from cooperative-pool stalls'],cwd=root)
 subprocess.check_call(['git','push'],cwd=root)
 head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
 print(number,'PUSHED',head,flush=True)
