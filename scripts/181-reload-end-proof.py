#!/usr/bin/env python3
"""Hosted-only review regressions: expected old failures, all focused consumers fixed."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess
ROOT=Path.cwd()
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
SOURCE='4e80d3a55755ecfdf491752e94268c959514aafc';BEFORE='920c605edb7f15f0798fce444e66adf36ff965c3'
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==SOURCE
OUT=ROOT/'build/181-reload-end-proof';OUT.mkdir(parents=True,exist_ok=True)
PACKAGE=OUT/'package';TESTS=PACKAGE/'Tests/ConsumerProof';TESTS.mkdir(parents=True,exist_ok=True)
(PACKAGE/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"ConsumerProof",platforms:[.macOS(.v15)],dependencies:[.package(path:'+json.dumps(str(ROOT))+')],targets:[.testTarget(name:"ConsumerProof",dependencies:[.product(name:"CassiniBrowserControl",package:'+json.dumps(ROOT.name)+'),.product(name:"CassiniRecording",package:'+json.dumps(ROOT.name)+'),.product(name:"CassiniKit",package:'+json.dumps(ROOT.name)+')])])\n')
(PACKAGE/'browser-protocol').symlink_to(ROOT/'browser-protocol',target_is_directory=True)
testFiles=['VerifiedAdmissionTests.swift','CallSignalTests.swift','OwnedCallProofLossTests.swift']
for name in testFiles:shutil.copyfile(ROOT/'Tests/CassiniBrowserControlTests'/name,TESTS/name)
files=[ROOT/'Sources/CassiniBrowserControl'/name for name in ['CallSignals.swift','VerifiedCallAdmission.swift']]
original={p:p.read_bytes() for p in files}
summary=dict(sourceHead=SOURCE,beforeHead=BEFORE,architecture=os.uname().machine,sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(data).hexdigest() for p,data in original.items()},testSHA256={name:hashlib.sha256((TESTS/name).read_bytes()).hexdigest() for name in testFiles})
def run(label,selector):
 with (OUT/(label+'.log')).open('w') as out:
  value=subprocess.run(['swift','test','-j','2','--package-path',str(PACKAGE),'-Xswiftc','-enable-testing','--filter',selector],stdout=out,stderr=subprocess.STDOUT,timeout=900)
 return value.returncode,(OUT/(label+'.log')).read_text()
try:
 for p in files:p.write_bytes(subprocess.check_output(['git','show',BEFORE+':'+str(p.relative_to(ROOT))]))
 before,log=run('before','CurrentReloadEnd')
 expected=['testCurrentReloadEndRetiresAllMixedAssociationsOfTheSameCall','testCurrentReloadEndImmediatelyFencesSeparatedFallbackOwner']
 failed=re.findall(r"Test Case '[^']+ (test\w+)\]' failed",log)
 summary['before']=dict(exitStatus=before,failedTests=failed)
 (OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 assert before!=0 and sorted(failed)==sorted(expected),log[-6000:]
finally:
 for p,data in original.items():p.write_bytes(data)
after,log=run('after','OwnedCallProofLossTests|CallSignalTests|VerifiedAdmissionTests')
summary['after']=dict(exitStatus=after,passed44=bool(re.search(r'Executed 44 tests, with 0 failures',log)))
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
assert after==0 and summary['after']['passed44'],log[-6000:]
print(json.dumps(summary,indent=2))
