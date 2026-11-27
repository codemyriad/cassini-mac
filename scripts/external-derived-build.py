#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run one release build with its DerivedData (and optionally staged output) on an external volume.

    external-derived-build.py --preflight ROOT
    external-derived-build.py [--stage-output DEST] ROOT COMMAND [ARG...]

Started by the test-release scheduler through the logged-in (Aqua) session's runner, because a LaunchAgent has no
access to removable volumes. `--preflight` verifies in that session that ROOT is mounted, has space and is writable
before the scheduler reserves a build number. Build mode makes a private folder under ROOT, appends
`--derived-data FOLDER` (and `--output STAGED` when `--stage-output DEST` is given) to COMMAND, waits for it,
copies only the finished DMG/reports (or bounded diagnostic tails on failure) into DEST, and removes the external
folder again, whatever the outcome. The scheduler itself never touches ROOT.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

VOLUMES=Path('/Volumes')
RESERVE=25*1024**3
DIAGNOSTIC_TAIL=1024**2
DIAGNOSTIC_FILES=('build.log','app-notary.json','dmg-notary.json')
# Below the scheduler's own six-hour limit, so this process still removes its folder and reports the timeout.
TIMEOUT=21000


def external_root(text):
    """An absolute path without symlinks inside a volume that is mounted now. A missing volume leaves an ordinary
    folder (or nothing) at /Volumes/NAME on the internal disk: writing there is exactly what this must not do."""
    root=Path(text)
    if not root.is_absolute() or '..' in root.parts or not root.is_relative_to(VOLUMES) \
            or len(root.relative_to(VOLUMES).parts)<2:
        raise ValueError('External build root must be a folder inside /Volumes/<volume>')
    volume=VOLUMES/root.relative_to(VOLUMES).parts[0]
    if not os.path.ismount(volume):
        raise ValueError('External build volume is not mounted')
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    if root.resolve()!=root:
        raise ValueError('External build root must not follow symlinks')
    return root


def group_alive(group):
    """Whether a process of the group can still run. macOS answers EPERM for a group whose remaining members have
    all ended and only wait to be collected; the build's processes are this user's, so nothing else gives EPERM."""
    try:os.killpg(group,0)
    except (ProcessLookupError,PermissionError):return False
    return True


def stop_group(process,grace=30):
    """Ends every process of the build's own group and returns only when none is left: the leader may exit on
    SIGTERM while a descendant ignores it, and nothing of the build may still run when its folder is removed."""
    group=process.pid
    if group_alive(group):
        try:os.killpg(group,signal.SIGTERM)
        except ProcessLookupError:pass
        deadline=time.monotonic()+grace
        while group_alive(group) and time.monotonic()<deadline:
            if process.poll() is None:
                try:process.wait(timeout=0.05)
                except subprocess.TimeoutExpired:pass
            else:time.sleep(0.05)
    while group_alive(group):
        try:os.killpg(group,signal.SIGKILL)
        except (ProcessLookupError,PermissionError):break
        process.poll()  # Reap the leader; the others are reaped by launchd once killed.
        time.sleep(0.05)
    process.wait()


def preflight(root,reserve=RESERVE,free=lambda path:shutil.disk_usage(path).free):
    """Checks in the logged-in session that ROOT is on a mounted external volume with space and write access."""
    root=external_root(root)
    if free(root)<reserve:
        raise ValueError('At least25GiB free required on the external build volume')
    probe=Path(tempfile.mkdtemp(prefix='preflight-',dir=root))
    probe.rmdir()
    return root


def stage_destination(text):
    dest=Path(text)
    if not dest.is_absolute() or '..' in dest.parts:
        raise ValueError('Staged output destination must be an absolute path without ..')
    if dest.exists() or dest.is_symlink():
        raise ValueError('Staged output destination already exists')
    parent=dest.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError('Staged output parent must be an existing directory without symlinks')
    return dest


def _copy_tail(source,target,staged_root,limit=DIAGNOSTIC_TAIL):
    if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(staged_root):
        return
    with source.open('rb') as stream:
        stream.seek(max(0,source.stat().st_size-limit))
        data=stream.read(limit)
    with target.open('wb') as stream:
        stream.write(data)


def collect_staged_output(staged,dest,succeeded):
    """Copy only the finished publishable artifacts (or bounded diagnostic tails) from the external staging dir."""
    if staged.is_symlink() or not staged.is_dir():
        if succeeded:
            raise ValueError('Staged release output is missing')
        return
    staged_root=staged.resolve()
    dest.mkdir(mode=0o700,exist_ok=False)
    for name in DIAGNOSTIC_FILES:
        _copy_tail(staged/name,dest/name,staged_root)
    if not succeeded:
        _copy_tail(staged/'test-release.json',dest/'test-release.json',staged_root)
        return
    report_src=staged/'test-release.json'
    sums_src=staged/'SHA256SUMS'
    for path in (report_src,sums_src):
        if path.is_symlink() or not path.is_file() or path.resolve().parent!=staged_root:
            raise ValueError('Staged release report is missing or invalid')
    report=json.loads(report_src.read_text())
    dmg_name=report.get('dmg') if isinstance(report,dict) else None
    if not isinstance(dmg_name,str) or Path(dmg_name).name!=dmg_name or dmg_name in ('','.','..'):
        raise ValueError('Staged release DMG name is invalid')
    dmg_src=staged/dmg_name
    if dmg_src.is_symlink() or not dmg_src.is_file() or dmg_src.resolve().parent!=staged_root:
        raise ValueError('Staged release DMG is missing or invalid')
    for src in (report_src,sums_src,dmg_src):
        shutil.copyfile(src,dest/src.name)


def build(root,command,reserve=RESERVE,timeout=TIMEOUT,free=lambda path:shutil.disk_usage(path).free,started=None,grace=30,stage_output=None):
    """`started` is called with the running process (tests wait there for the build to be ready)."""
    root=external_root(root)
    dest=stage_destination(stage_output) if stage_output is not None else None
    if free(root)<reserve:
        raise ValueError('At least25GiB free required on the external build volume')
    work=Path(tempfile.mkdtemp(prefix='derived-',dir=root))
    derived=(work/'derived') if dest is not None else work
    staged=(work/'release') if dest is not None else None
    argv=[*command,'--output',str(staged),'--derived-data',str(derived)] if dest is not None else [*command,'--derived-data',str(derived)]
    process=None
    try:
        process=subprocess.Popen(argv,start_new_session=True)
        if started:started(process)
        try:
            code=process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print('Test build timed out; stopping its process group',file=sys.stderr)
            code=124
        stop_group(process,grace)
        process=None
        if dest is not None:
            collect_staged_output(staged,dest,code==0)
        return code
    finally:
        # Also after an ordinary exit: whatever the build left running in its own group (its heavy-lock wrapper,
        # a compiler) ends before the folder under it goes, so no compiler keeps the shared lock or writes there.
        if process is not None:stop_group(process,grace)
        shutil.rmtree(work,ignore_errors=True)


if __name__=='__main__':
    args=sys.argv[1:]
    if len(args)==2 and args[0]=='--preflight':
        try:
            preflight(args[1])
        except (ValueError,OSError) as error:
            print(str(error),file=sys.stderr)
            raise SystemExit(2)
        raise SystemExit(0)
    stage_output=None
    if args[:1]==['--stage-output']:
        if len(args)<4:
            raise SystemExit(__doc__)
        stage_output=args[1]
        args=args[2:]
    if len(args)<2:
        raise SystemExit(__doc__)
    try:
        raise SystemExit(build(args[0],args[1:],stage_output=stage_output))
    except (ValueError,OSError) as error:
        print(str(error),file=sys.stderr)
        raise SystemExit(2)
