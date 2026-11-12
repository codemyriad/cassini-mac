#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Install only the reviewed main pipeline on drmeyers. No build or key access."""
import os
from pathlib import Path
import plistlib
import socket
import shutil
import subprocess
import sys

def installed_python(path=None):
    """Use an installed interpreter; preserve stable Homebrew/Xcode symlinks."""
    if path is None:
        runtime=Path(sys.executable).resolve()
        candidates=[]
        # macOS framework launchers may expose a versioned Cellar binary in
        # sys.executable. Prefer a stable entrypoint for that exact runtime.
        found=shutil.which('python3')
        if found:candidates.append(Path(found))
        if 'Cellar' in runtime.parts:
            index=runtime.parts.index('Cellar')
            prefix=Path(*runtime.parts[:index]);formula=runtime.parts[index+1]
            bin_dir=prefix/'opt'/formula/'bin'
            candidates.extend([bin_dir/'python3',*sorted(bin_dir.glob('python3.*'))])
        candidates.extend(Path(p) for p in ['/opt/homebrew/bin/python3','/usr/local/bin/python3','/usr/bin/python3'])
        for candidate in candidates:
            if not candidate.is_file() or not os.access(candidate,os.X_OK):continue
            same=candidate.resolve()==runtime
            if not same:
                try:
                    probe=subprocess.run([str(candidate),'-c','import os,sys; print(os.path.realpath(sys.executable))'],
                                         capture_output=True,text=True,timeout=30)
                    same=probe.returncode==0 and probe.stdout.strip()==str(runtime)
                except (OSError,subprocess.TimeoutExpired):continue
            if same:
                path=candidate;break
    python=Path(os.path.abspath(Path(path or sys.executable).expanduser()))
    if not python.is_file() or not os.access(python,os.X_OK):
        raise ValueError('Select an installed Python executable with --python')
    check=subprocess.run([str(python),'-c',
        'import sys,venv; from zoneinfo import ZoneInfo; ZoneInfo("Europe/Berlin"); sys.exit(0 if sys.version_info >= (3,9) else 1)'],
        capture_output=True,timeout=30)
    if check.returncode:raise ValueError('Python 3.9+ with venv and zoneinfo is required')
    return python


def install(python=None,derived_root=None,aqua=None):
    if sys.platform!='darwin' or socket.gethostname().split('.')[0].lower()!='drmeyers':
        raise SystemExit('Install the test-release scheduler only on drmeyers')
    python=installed_python(python)
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
    runtime_paths=[python.parent]
    libexec=python.parent.parent/'libexec/bin'
    if libexec.is_dir():runtime_paths.append(libexec)
    agent=Path.home()/'Library/LaunchAgents'/(label+'.plist');agent.parent.mkdir(parents=True,exist_ok=True)
    environment={'PATH':':'.join(map(str,runtime_paths))+':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'}
    if derived_root or aqua:
        # DerivedData on an external volume, built through the logged-in session (scripts/daily-test-release.py
        # `external_build`). The scheduler checks both values again at every build.
        if not derived_root or not aqua:raise SystemExit('--derived-root and --aqua go together')
        environment.update(CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT=str(derived_root),CASSINI_MAC_TEST_RELEASE_AQUA=str(aqua))
    agent.write_bytes(plistlib.dumps(dict(Label=label,ProgramArguments=[str(python),str(script)],
        RunAtLoad=True,StartInterval=60,
        EnvironmentVariables=environment,
        StandardOutPath=str(base/'scheduler.log'),StandardErrorPath=str(base/'scheduler-error.log'))))
    # Minute pulses discover manual requests and catch up a missed Berlin slot;
    # state deduplicates each09:00/14:00/20:00 attempt. No sleep/retry loop.
    subprocess.run(['launchctl','bootstrap',domain,str(agent)],check=True)
    print('Installed Berlin scheduler and manual-request bridge; signing keys remain unchanged')


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python',type=Path,help='Installed Python 3.9+; defaults to the interpreter running this installer')
    parser.add_argument('--derived-root',type=Path,help='Folder inside /Volumes/<volume> for each build\'s DerivedData')
    parser.add_argument('--aqua',type=Path,help='Program that runs a command in the logged-in session (drmeyers: ~/bin/guirun); required with --derived-root')
    arguments=parser.parse_args()
    install(arguments.python,arguments.derived_root,arguments.aqua)
