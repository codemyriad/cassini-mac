from pathlib import Path
import subprocess, sys, shutil, difflib
base=Path('/tmp/cassini-aws-d88-before'); scratch='/tmp/cassini-aws-d88-before-build'
def run(selected, log):
    log.parent.mkdir(parents=True,exist_ok=True)
    with log.open('w') as out:
        rc=subprocess.call(['swift','test','--package-path',str(base),'--scratch-path',scratch,'--jobs','4','--filter',selected],stdout=out,stderr=subprocess.STDOUT)
    print(str(log),rc,flush=True)
    return rc
# Remaining-area baselines use the unchanged baseline checkout.
if not Path('/tmp/aws-other-before.log').exists():
    run('SessionPlaybackTests|InstallationTests|BackgroundSetupTests|LibraryWatcherTests|PipeTransportTests|ControlHostTests',Path('/tmp/aws-other-before.log'))
areas=[('ipc',Path('/Users/ec2-user/agents/cassini-mac'),'ControlServiceTests',[('Sources/CassiniBrowserControl/ControlRegistry.swift','peer.meetings = meetings','peer.meetings = meetings; peer.reconciled = true','ControlServiceTests.testProfilesWithSameTabStaySeparateAndWaitForTheirOwnFirstStatus','premature-start'),('Sources/CassiniBrowserControl/ControlRegistry.swift','peer.captures = current.captures; peer.interrupted = current.interrupted','peer.captures = current.captures; peer.interrupted = current.interrupted; peer.autoAttempted = []; peer.requestedStops = []','ControlServiceTests.testAutomaticStartIsNotAnnouncedUntilItsAcknowledgementAndStopDoesNotRestart','restart-after-stop')]),('browser',Path('/tmp/cassini-aws-d88-browser'),'AudioBrokerTests|InputLifecycleTests|D52SourceOutcomeTests',[('Sources/CassiniBrowserControl/CaptureInputLifecycle.swift','guard !self.closed, let input = self.inputs[side], input.generation == generation else { return }','guard !self.closed, let input = self.inputs[side] else { return }','InputLifecycleTests.testRetryMePreservesSystemAndIgnoresFailureFromPreviousMic','stale-failure')]),('playback',Path('/tmp/cassini-aws-d88-playback'),'SessionPlaybackTests',[('Sources/CassiniPlayback/SessionPlayback.swift','deinit { task?.cancel() }','deinit {}','SessionPlaybackTests.abandonedPreparationIsCancelledWithItsOwner','owner-cancel')]),('setup',Path('/tmp/cassini-aws-d88-setup'),'InstallationTests|BackgroundSetupTests|LibraryWatcherTests',[('Sources/CassiniBrowserSetup/BackgroundSetup.swift','if attempt != nil { again = true; return }','if attempt != nil { return }','BackgroundSetupTests.testEventsDuringAttemptCoalesceWithoutBlockingUIActor','drop-coalesced')])]
for name,root,selected,mutations in areas:
    if len(sys.argv)>1 and areas.index((name,root,selected,mutations)) < int(sys.argv[1]): continue
    out=root/('evidence/mac/d88/aws-'+name)
    out.mkdir(parents=True,exist_ok=True)
    # Copy only each branch's changed Swift files into the pristine baseline tree.
    paths=subprocess.check_output(['git','diff','main','--name-only','HEAD'],cwd=root,text=True).splitlines()
    paths+=subprocess.check_output(['git','diff','--name-only'],cwd=root,text=True).splitlines()
    paths=list(dict.fromkeys(p for p in paths if p.endswith('.swift')))
    originals={p:(base/p).read_bytes() for p in paths}
    try:
        for p in paths: shutil.copyfile(root/p,base/p)
        if run(selected,out/'after.log'):
            print('STOP: after failed in '+name,flush=True); sys.exit(1)
        for path,old,new,filtered,label in mutations:
            target=base/path; original=target.read_text(); assert old in original
            try:
                target.write_text(original.replace(old,new))
                (out/(label+'.patch')).write_text("".join(difflib.unified_diff(original.splitlines(True),target.read_text().splitlines(True),fromfile="a/"+path,tofile="b/"+path)))
                if run(filtered,out/(label+'.log'))==0:
                    print('STOP: mutation survived '+label,flush=True); sys.exit(1)
            finally: target.write_text(original)
        if run(selected,out/'restored.log'): sys.exit(1)
    finally:
        for p,data in originals.items(): (base/p).write_bytes(data)
