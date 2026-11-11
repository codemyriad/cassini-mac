#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Install only the reviewed main pipeline on drmeyers. No build or key access."""
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys

if sys.platform!='darwin' or socket.gethostname().split('.')[0].lower()!='drmeyers':
    raise SystemExit('Install the test-release scheduler only on drmeyers')
label='io.codemyriad.cassini.daily-test-release'
domain='gui/'+str(os.getuid())
loaded=subprocess.run(['launchctl','print',domain+'/'+label],capture_output=True)
if loaded.returncode==0:raise SystemExit('Agent already loaded; unload only after its current job finishes')
base=Path.home()/'.local/share/cassini-mac-test-releases'
if base.resolve()!=base:raise SystemExit('Dedicated release storage must not follow symlinks')
base.mkdir(parents=True,exist_ok=True);os.chmod(base,0o700)
source=base/'source'
if source.is_symlink():raise SystemExit('Dedicated release checkout must not be a symlink')
marker=base/'owned-checkout'
if source.exists() and not marker.is_file():raise SystemExit('Refusing an existing unowned checkout')
if not source.exists():
    subprocess.run(['git','clone','--branch','main','https://github.com/codemyriad/cassini-mac',str(source)],check=True)
    marker.write_text('cassini-mac-test-releases\n')
if subprocess.check_output(['git','-C',str(source),'remote','get-url','origin'],text=True).strip()!='https://github.com/codemyriad/cassini-mac':
    raise SystemExit('Unexpected dedicated source origin')
subprocess.run(['git','-C',str(source),'fetch','origin','main'],check=True)
subprocess.run(['git','-C',str(source),'checkout','--detach','--force','origin/main'],check=True)
script=source/'scripts/daily-test-release.py'
if not script.is_file():raise SystemExit('Merge the pipeline PR into main before installing')
agent=Path.home()/'Library/LaunchAgents'/(label+'.plist');agent.parent.mkdir(parents=True,exist_ok=True)
python=Path('/opt/homebrew/opt/python@3.12/bin/python3.12')
if not python.is_file():raise SystemExit('Install the existing pipeline requirement Python3.12 before enabling')
agent.write_bytes(plistlib.dumps(dict(Label=label,ProgramArguments=[str(python),str(script)],
    RunAtLoad=True,StartInterval=60,
    EnvironmentVariables={'PATH':'/opt/homebrew/opt/python@3.12/libexec/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
    StandardOutPath=str(base/'scheduler.log'),StandardErrorPath=str(base/'scheduler-error.log'))))
# Minute pulses discover manual requests and catch up a missed Berlin slot;
# state deduplicates each09:00/14:00/20:00 attempt. No sleep/retry loop.
subprocess.run(['launchctl','bootstrap',domain,str(agent)],check=True)
print('Installed Berlin scheduler and manual-request bridge; signing keys remain unchanged')
