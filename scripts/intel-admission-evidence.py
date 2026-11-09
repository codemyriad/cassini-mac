#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Counterbalanced full-suite experiment; production/default admission stays unlimited."""
import json,os,re,select,shutil,signal,statistics,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
order=sys.argv[1];assert order in ['unlimited-first','limited-first']
base=root/'build/intel-admission';package=base/'package';target=package/'Tests/ModelsProof';target.mkdir(parents=True,exist_ok=True)
(package/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\n'+
 'let package=Package(name:"PythonStackProof",platforms:[.macOS(.v15)],dependencies:[.package(path:'+json.dumps(str(root))+')],targets:[.testTarget(name:"ModelsProof",dependencies:[.product(name:"CassiniModels",package:'+json.dumps(root.name)+')],resources:[.copy("Fixtures")])])\n')
shutil.copyfile(root/'Tests/CassiniModelsTests/ModelDownloaderTests.swift',target/'ModelDownloaderTests.swift')
shutil.copytree(root/'Tests/CassiniModelsTests/Fixtures',target/'Fixtures',dirs_exist_ok=True)
subprocess.run(['swift','build','--build-tests','-j','2','--package-path',str(package)],check=True)
labels=['unlimited','limited'] if order=='unlimited-first' else ['limited','unlimited'];results={}
for label in labels:
    children=base/label;children.mkdir(exist_ok=True)
    env=dict(os.environ,CASSINI_FIXTURE_DIAGNOSTICS=str(children),CASSINI_FIXTURE_BOOTSTRAP_LIMIT='2' if label=='limited' else '0')
    with (base/f'{label}.log').open('w') as output:
        result=subprocess.run(['swift','test','--skip-build','--package-path',str(package),'--filter','ModelDownloaderTests'],env=env,stdout=output,stderr=subprocess.STDOUT)
    values=[json.loads(p.read_text()) for p in children.glob('*.json')]
    elapsed=sorted(v['elapsedMs'] for v in values if v['ready']);log=(base/f'{label}.log').read_text()
    suite=re.search(r'Suite ModelDownloaderTests (?:passed|failed) after ([\d.]+) seconds',log)
    results[label]={'exitStatus':result.returncode,'ready':len(elapsed),'medianMs':statistics.median(elapsed) if elapsed else None,
                    'maximumMs':max(elapsed) if elapsed else None,'suiteSeconds':float(suite[1]) if suite else None,
                    'unexpectedFailures':[v for v in values if not v['ready'] and v['scenario'] not in ['no-ready','invalid-ready']]}
    # A test process can exit before its asynchronous fixture deinit finishes.
    # Reap only recorded children whose exact unique fixture/log argv still match.
    cleanup=[]
    for v in values:
        pid=v['pid']
        try:
            os.kill(pid,0)
            args=subprocess.check_output(['/bin/ps','-ww','-p',str(pid),'-o','args='],text=True)
            if v['arguments'][1] not in args or v['arguments'][5] not in args:continue
            with select.kqueue() as queue:
                queue.control([select.kevent(pid,filter=select.KQ_FILTER_PROC,flags=select.KQ_EV_ADD|select.KQ_EV_ONESHOT,fflags=select.KQ_NOTE_EXIT)],0)
                os.kill(pid,signal.SIGTERM)
                if not queue.control(None,1,2):
                    os.kill(pid,signal.SIGKILL);queue.control(None,1,2)
            cleanup.append(pid)
        except (ProcessLookupError,ValueError,subprocess.CalledProcessError):pass
    (base/f'{label}-cleanup.json').write_text(json.dumps(cleanup)+'\n')
    (base/'results.json').write_text(json.dumps({'order':order,'results':results},indent=2)+'\n')
    print(label,results[label],flush=True)
assert all(r['exitStatus']==0 for r in results.values()),results
