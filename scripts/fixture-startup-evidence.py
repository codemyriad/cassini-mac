#!/usr/bin/env python3
"""Diagnostic only: observe the original Intel test process without changing its deadlines."""
import json, os, selectors, shutil, signal, subprocess, sys, time
from pathlib import Path
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
interpreter=shutil.which('python3')
(out/'environment.json').write_text(json.dumps({'PATH':os.environ.get('PATH'),'python3':interpreter,'resolved':str(Path(interpreter).resolve()) if interpreter else None},indent=2))
p=subprocess.Popen(['swift','test','--skip-build','--filter','ModelDownloaderTests'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
start=None; points=iter([2,5,8]);next_point=None; tail=b''
def snapshot(label):
    raw=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,state=,comm='],text=True,timeout=5)
    rows=[row.strip().split(None,3) for row in raw.splitlines()]
    owned={p.pid}
    for _ in rows:
        added={int(pid) for pid,parent,_,_ in rows if int(parent) in owned}
        if added<=owned:break
        owned|=added
    selected=[row for row in rows if int(row[0]) in owned]
    (out/f'processes-{label}.json').write_text(json.dumps(selected,indent=2))
    if label==5:
        targets=[int(pid) for pid,_,_,name in selected if 'python' in name.lower() or 'xcodebuild' in name.lower()]
        for pid in targets[:2]:
            with (out/f'sample-{pid}.log').open('w') as log:
                try:subprocess.run(['/usr/bin/sample',str(pid),'1','10','-file',str(out/f'stack-{pid}.txt')],stdout=log,stderr=subprocess.STDOUT,timeout=5)
                except subprocess.SubprocessError as error:log.write(str(error))
try:
    with selectors.DefaultSelector() as events,(out/'tests.log').open('wb') as log:
        events.register(p.stdout,selectors.EVENT_READ)
        while True:
            elapsed=0 if start is None else time.monotonic()-start
            if next_point is not None and elapsed>=next_point:
                snapshot(next_point);next_point=next(points,None)
            # Timed diagnostic sampling only; test synchronization remains its real pipe events.
            for _,_ in events.select(timeout=max(0.01,min(1,next_point-elapsed)) if next_point is not None else 1):
                chunk=os.read(p.stdout.fileno(),65536)
                if not chunk:sys.exit(p.wait(timeout=10))
                log.write(chunk);log.flush();sys.stdout.buffer.write(chunk);sys.stdout.buffer.flush()
                tail=(tail+chunk)[-65536:]
                if start is None and b'Suite ModelDownloaderTests started.' in tail:
                    start=time.monotonic();next_point=next(points,None)
finally:
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=10)
