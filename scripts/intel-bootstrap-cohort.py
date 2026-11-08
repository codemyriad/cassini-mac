#!/usr/bin/env python3
"""Hosted-only controlled model-fixture bootstrap burst; every child keeps the original 10s bound."""
import argparse
import hashlib
import json
import os
import selectors
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--admission',type=int,choices=[1,32],required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
a.output.mkdir(parents=True,exist_ok=False)
fixture=Path('Tests/CassiniModelsTests/Fixtures/server.py').resolve()
python=shutil.which('python3'); assert python
children=[]; pending={}; records=[]; samplers=[]
selector=selectors.DefaultSelector(); count=32

def capture(child,stem):
    # Sampling is only triggered AFTER that specific child's actual readiness deadline.
    try:
        info=subprocess.check_output(['/bin/ps','-p',str(child.pid),'-o','pid=,ppid=,state=,etime=,time=,command='],text=True,timeout=3)
        (a.output/(stem+'.process.txt')).write_text(info)
        subprocess.run(['/usr/bin/sample',str(child.pid),'1','10','-file',str(a.output/(stem+'.stack.txt'))],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=4,check=False)
    except Exception as error:
        (a.output/(stem+'.sample-error.txt')).write_text(str(error))

def launch():
    index=len(children); stem=f'{index:02d}'
    errors=(a.output/(stem+'.stderr.txt')).open('wb')
    began=time.monotonic()
    child=subprocess.Popen(['/usr/bin/env','python3',str(fixture),'--scenario','normal','--log',str((a.output/(stem+'.requests.jsonl')).resolve()),'--forbid-dns'],
                           stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,start_new_session=True)
    errors.close(); children.append(child)
    entry=dict(index=index,pid=child.pid,launchedMonotonic=began,spawnMs=(time.monotonic()-began)*1000,data=b'',child=child,deadline=time.monotonic()+10)
    pending[child.pid]=entry
    selector.register(child.stdout,selectors.EVENT_READ,child.pid)

def finish(pid,status):
    entry=pending.pop(pid); selector.unregister(entry['child'].stdout)
    record={key:entry[key] for key in ['index','pid','launchedMonotonic','spawnMs']}
    record.update(status=status,elapsedMs=(time.monotonic()-entry['launchedMonotonic'])*1000,stdout=entry['data'].decode(errors='replace'))
    records.append(record)
    if status=='timeout':
        thread=threading.Thread(target=capture,args=(entry['child'],f'{entry["index"]:02d}'))
        thread.start(); samplers.append(thread)

try:
    while len(records)<count:
        while len(children)<count and len(pending)<a.admission:
            launch()
        timeout=max(0,min(e['deadline'] for e in pending.values())-time.monotonic())
        for key,_ in selector.select(timeout):
            pid=key.data
            if pid not in pending:continue
            entry=pending[pid]; chunk=os.read(key.fileobj.fileno(),4096)
            entry['data']+=chunk
            if b'\n' in entry['data']:
                line=entry['data'].split(b'\n',1)[0]
                finish(pid,'ready' if line.startswith(b'http://127.0.0.1:') else 'invalid')
            elif not chunk:finish(pid,'exited')
        for pid in list(pending):
            if time.monotonic()>=pending[pid]['deadline']:finish(pid,'timeout')
    for thread in samplers:thread.join(timeout=6)
finally:
    selector.close()
    for child in children:
        if child.poll() is None:
            os.killpg(child.pid,signal.SIGTERM)
        try:child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=3)
    result=dict(admission=a.admission,count=count,python=python,resolvedPython=str(Path(python).resolve()),
                fixtureSha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),deadlineSeconds=10,
                sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
                records=sorted(records,key=lambda r:r['index']),scope='Bootstrap only; every server stays alive through cohort. No downloads, app, devices or user data. Independent fresh runner for each admission width.')
    (a.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['admission','count','resolvedPython','deadlineSeconds']}))
    print('ready',sum(r['status']=='ready' for r in records),'timeouts',sum(r['status']=='timeout' for r in records),'max elapsed ms',max(r['elapsedMs'] for r in records))
