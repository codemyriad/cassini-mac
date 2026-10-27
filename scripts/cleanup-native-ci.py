#!/usr/bin/env python3
"""Clean only processes and temporary profiles owned by this native CI job."""
import argparse, json, os, pathlib, shutil, signal, subprocess, time
parser = argparse.ArgumentParser()
parser.add_argument('--native-build', type=pathlib.Path, required=True)
parser.add_argument('--profiles', type=pathlib.Path, required=True)
parser.add_argument('--report', type=pathlib.Path)
args = parser.parse_args()
build = str(args.native_build.resolve())
profiles = args.profiles.resolve()
assert profiles.name.startswith('cassini-browser-profiles-'), 'Refusing an unowned profile directory'
uid = os.getuid()
def owned():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,uid=,command='], text=True).splitlines()
    found = []
    for row in rows:
        parts = row.strip().split(None, 2)
        if len(parts) != 3 or int(parts[1]) != uid: continue
        pid, command = int(parts[0]), parts[2]
        diagnostic = build + '/Build/Products/Debug/Cassini.app/Contents/MacOS/Cassini' in command and '--recording-ci-run=' in command
        browser = '--user-data-dir=' + str(profiles) + '/' in command
        if pid != os.getpid() and (diagnostic or browser): found.append(pid)
    return found
pids = owned()
for pid in pids:
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
if pids:
    time.sleep(1)
    for pid in owned():
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
if profiles.exists(): shutil.rmtree(profiles)
result = dict(terminated=pids, removedProfileDirectory=str(profiles), scope='this job only')
if args.report:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
