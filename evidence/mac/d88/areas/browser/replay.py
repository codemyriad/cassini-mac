from pathlib import Path
import os,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[5]
BASE='ade442cb17b958e4c3d7c18512f7b4e92b78214d'
OUT=Path(os.environ['D88_EVIDENCE_DIR']).resolve();OUT.mkdir(parents=True,exist_ok=True)
WORK=Path(tempfile.mkdtemp(prefix='d88-browser-review-'))
subprocess.run(['tar','-xf','-','-C',str(WORK)],input=subprocess.check_output(['git','archive',BASE],cwd=ROOT),check=True)
SUITE='ControlServiceTests|AudioBrokerTests|InputLifecycleTests|D52SourceOutcomeTests'
CASES={
 'profile-first-status':'testProfilesWithSameTabStaySeparateAndWaitForTheirOwnFirstStatus',
 'stopped-call-barrier':'testAutomaticStartIsNotAnnouncedUntilItsAcknowledgementAndStopDoesNotRestart',
 'factory-drain':'testShutdownClosesAdmissionAndWaitsForAnInFlightFolderFactory',
 'shared-finalization':'testConcurrentAppStopsAndQuitShareOneNativeDrain',
 'microphone-pcm':'testRealNativeProcessesRecordIndependentFilesAndStopOnlyTheirOwnCapture',
 'permission-registration':'testRepeatedPageChangesCancelWaitersButKeepOnlyOnePendingOSRequest',
 'stale-failure':'testRetryMePreservesSystemAndIgnoresFailureFromPreviousMic',
}
def run(name,test,positive):
 log=OUT/(name+'.log')
 with log.open('w') as stream:
  result=subprocess.run(['swift','test','--scratch-path',str(WORK/'build'),'--jobs','4','--filter',test],cwd=WORK,stdout=stream,stderr=subprocess.STDOUT,timeout=240)
 text=log.read_text()
 if positive:assert result.returncode==0,name
 else:
  assert result.returncode!=0 and 'XCTAssert' in text and ' failed (' in text,name
  assert not any(s in text for s in ('Asynchronous wait failed','SWIFT TASK CONTINUATION MISUSE','error: fatalError')),name
run('before',SUITE,True)
subprocess.run(['git','apply','-'],cwd=WORK,input=subprocess.check_output(['git','diff',BASE,'HEAD','--','Sources','Tests'],cwd=ROOT),check=True)
run('after',SUITE,True)
for name,test in CASES.items():
 patch=(Path(__file__).parent/(name+'.patch')).read_bytes()
 subprocess.run(['git','apply','--unidiff-zero','-'],cwd=WORK,input=patch,check=True)
 try:run(name,test,False)
 finally:subprocess.run(['git','apply','--reverse','--unidiff-zero','-'],cwd=WORK,input=patch,check=True)
run('restored',SUITE,True)
print('73-case before/after/restored suite and seven behavioral production mutations passed')
