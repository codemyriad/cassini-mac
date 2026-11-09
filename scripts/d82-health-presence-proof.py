#!/usr/bin/env python3
"""Hosted-only, same-bundle ABBA proof; preserve all nine health variants/actions/assertions."""
from pathlib import Path
import hashlib,json,os,re,statistics,subprocess
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
ROOT=Path.cwd();OUT=ROOT/'build/d82-health-presence';OUT.mkdir(parents=True,exist_ok=True)
CASES=['testCompanionHealthUsesExplicitTabAdviceAndFileCheckedSetup']
specs=list((ROOT/'build/Build/Products').glob('*.xctestrun'));assert len(specs)==1,specs
report=dict(head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),sourceSHA256={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['UITests/WindowlessApp.swift','UITests/LibraryBoards.swift']},phases=[])
for index,mode in enumerate(['original','fast','fast','original']):
 label=f'{index+1}-{mode}'
 env=dict(os.environ,TEST_RUNNER_CASSINI_HOSTED_SCREENSHOTS='1',TEST_RUNNER_CASSINI_LIBRARY_BOARDS='1',TEST_RUNNER_CASSINI_D82_ORIGINAL_PRESENCE='1' if mode=='original' else '0')
 args=['xcodebuild','test-without-building','-xctestrun',str(specs[0]),'-destination','platform=macOS','-parallel-testing-enabled','NO']
 args += ['-only-testing:CassiniWindowScreenshots/LibraryBoards/'+case for case in CASES]
 args += ['-resultBundlePath',str(OUT/(label+'.xcresult'))]
 with (OUT/(label+'.log')).open('w') as out:result=subprocess.run(args,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=300)
 log=(OUT/(label+'.log')).read_text()
 times={name:float(seconds) for name,seconds in re.findall(r"Test Case '[^']+ (test\w+)\]' passed \(([0-9.]+) seconds\)",log)}
 phase=dict(label=label,mode=mode,exitStatus=result.returncode,testSeconds=times,originalQueries=log.count('D82 presence original'),fastReady=log.count('D82 presence fast ready'),fastWait=log.count('D82 presence fast wait'))
 report['phases'].append(phase);(OUT/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
 assert result.returncode==0 and set(times)==set(CASES),log[-6000:]
 if mode=='original':assert phase['originalQueries']>0 and not phase['fastReady'] and not phase['fastWait'],phase
 else:assert phase['originalQueries']==0 and phase['fastReady']+phase['fastWait']>0,phase
 print(json.dumps(phase),flush=True)
report['cases']={case:{mode:dict(samples=[p['testSeconds'][case] for p in report['phases'] if p['mode']==mode],median=statistics.median(p['testSeconds'][case] for p in report['phases'] if p['mode']==mode)) for mode in ['original','fast']} for case in CASES}
report['sumMedians']={mode:sum(v[mode]['median'] for v in report['cases'].values()) for mode in ['original','fast']}
report['reductionPercent']=100*(1-report['sumMedians']['fast']/report['sumMedians']['original'])
(OUT/'comparison.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2),flush=True)
