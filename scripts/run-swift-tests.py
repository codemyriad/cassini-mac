#!/usr/bin/env python3
"""Run an owned test process group; retain stacks before a progress stall is killed."""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def stacks(pid, folder):
    rows = subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True,timeout=10)
    table = [line.strip().split(None,2) for line in rows.splitlines()]
    owned = {pid}
    for _ in table:
        added = {int(child) for child,parent,_ in table if int(parent) in owned}
        if added <= owned: break
        owned |= added
    selected = [row for row in table if int(row[0]) in owned]
    (folder/'processes.json').write_text(json.dumps(selected,indent=2)+'\n')
    targets = [int(child) for child,_,name in selected
               if Path(name).name in {'swiftpm-testing','swiftpm-testing-helper','xctest'}]
    for target in (targets or [pid])[:3]:
        with (folder/f'sample-{target}.log').open('w') as log:
            try:
                subprocess.run(['/usr/bin/sample',str(target),'1','10','-file',str(folder/f'stack-{target}.txt')],
                               stdout=log,stderr=subprocess.STDOUT,timeout=15)
            except (OSError,subprocess.SubprocessError) as error: log.write(str(error))


def run(command, folder, idle_seconds=120, diagnose=stacks, forward=True):
    folder.mkdir(parents=True,exist_ok=True)
    process = subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT,start_new_session=True)
    last = time.monotonic()
    try:
        with selectors.DefaultSelector() as events, (folder/'tests.log').open('wb') as log:
            events.register(process.stdout,selectors.EVENT_READ)
            while True:
                remaining = idle_seconds-(time.monotonic()-last)
                if remaining <= 0:
                    print(f'No test output for {idle_seconds}s; collecting owned-process stacks before termination',flush=True)
                    try: diagnose(process.pid,folder)
                    except Exception as error: (folder/'diagnostic-error.txt').write_text(str(error))
                    return 124
                ready = events.select(min(1,remaining))
                if not ready: continue
                chunk = os.read(process.stdout.fileno(),65536)
                if not chunk: return process.wait(timeout=10)
                last = time.monotonic();log.write(chunk);log.flush()
                if forward: sys.stdout.buffer.write(chunk);sys.stdout.buffer.flush()
    finally:
        # Only the process group created here, including stuck fixture children.
        if process.returncode is None:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
        process.wait(timeout=10);process.stdout.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('command',nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command: parser.error('command required')
    raise SystemExit(run(command,args.output))
