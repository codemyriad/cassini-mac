#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Admit hosted GUI CI or the dedicated console account; never spoof hosted."""
import os
from pathlib import Path
import subprocess

def admission(environment, uid, console_uid, aqua):
    if environment.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('GUI fixtures require Actions')
    kind=environment.get('RUNNER_ENVIRONMENT')
    if kind=='github-hosted':return 'hosted'
    if (kind=='self-hosted' and environment.get('CASSINI_CI_GUI')=='1'
            and uid==503 and console_uid==uid and aqua):return 'gui'
    raise ValueError('Expected hosted CI or the dedicated logged-in Aqua runner')

def check():
    uid=os.getuid()
    aqua=subprocess.run(['launchctl','print',f'gui/{uid}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    return admission(os.environ,uid,os.stat('/dev/console').st_uid,aqua)

def main():
    mode=check()
    if mode=='gui':
        subprocess.run(['/usr/bin/osascript','-e','set volume output muted true'],check=True)
        path=Path(os.environ['GITHUB_ENV'])
        with path.open('a') as output:
            output.write('CASSINI_LOCAL_WORKFLOW_TESTS=1\n')
    print('GUI fixture host:',mode)

if __name__=='__main__':main()
