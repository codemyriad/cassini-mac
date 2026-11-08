#!/usr/bin/env python3
"""Diagnostic only: observe actual owned fixture execs, independent of Swift output buffering."""
import json, os, selectors, shutil, signal, subprocess, sys, threading, time
from pathlib import Path
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
interpreter=shutil.which('python3')
(out/'environment.json').write_text(json.dumps({'PATH':os.environ.get('PATH'),'python3':interpreter,'resolved':str(Path(interpreter).resolve()) if interpreter else None},indent=2))
p=subprocess.Popen(['swift','test','--skip-build','--filter','ModelDownloaderTests'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
stop=threading.Event()
def owned_tree():
    raw=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,state=,comm='],text=True,timeout=5)
    rows=[row.strip().split(None,3) for row in raw.splitlines()]
    owned={p.pid}
    for _ in rows:
        added={int(pid) for pid,parent,_,_ in rows if int(parent) in owned}
        if added<=owned:break
        owned|=added
    return [row for row in rows if int(row[0]) in owned]
def snapshot(label,rows):
    (out/f'processes-{label}.json').write_text(json.dumps(rows,indent=2))
def monitor():
    try:
        while not stop.is_set():
            rows=owned_tree()
            targets=[int(pid) for pid,_,_,name in rows if 'python' in name.lower()]
            if targets:break
            stop.wait(.2)  # Diagnostic process discovery, never test synchronization.
        else:return
        start=time.monotonic();snapshot('fixture-exec',rows)
        for pid in targets[:2]:
            with (out/f'sample-{pid}.log').open('w') as log:
                try:subprocess.run(['/usr/bin/sample',str(pid),'1','10','-file',str(out/f'stack-{pid}.txt')],stdout=log,stderr=subprocess.STDOUT,timeout=5)
                except subprocess.SubprocessError as error:log.write(str(error))
        for point in (2,5,8):
            if stop.wait(max(0,point-(time.monotonic()-start))):break
            snapshot(point,owned_tree())
    except Exception as error:(out/'observer-error.txt').write_text(str(error))
observer=threading.Thread(target=monitor,daemon=True);observer.start()
try:
    with selectors.DefaultSelector() as events,(out/'tests.log').open('wb') as log:
        events.register(p.stdout,selectors.EVENT_READ)
        while True:
            for _,_ in events.select(timeout=1):
                chunk=os.read(p.stdout.fileno(),65536)
                if not chunk:sys.exit(p.wait(timeout=10))
                log.write(chunk);log.flush();sys.stdout.buffer.write(chunk);sys.stdout.buffer.flush()
finally:
    stop.set();observer.join(timeout=12)
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=10)
