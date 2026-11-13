#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run one release build with its DerivedData on an external volume.

    external-derived-build.py --preflight ROOT
    external-derived-build.py ROOT COMMAND [ARG...]

Started by the test-release scheduler through the logged-in (Aqua) session's runner, because a LaunchAgent has no
access to removable volumes. `--preflight` verifies in that session that ROOT is mounted, has space and is writable
before the scheduler reserves a build number. Build mode makes a private folder under ROOT, appends
`--derived-data FOLDER` to COMMAND, waits for it and removes the folder again, whatever the outcome. The scheduler
itself never touches ROOT.
"""
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


def build(root,command,reserve=RESERVE,timeout=TIMEOUT,free=lambda path:shutil.disk_usage(path).free,started=None,grace=30):
    """`started` is called with the running process (tests wait there for the build to be ready)."""
    root=external_root(root)
    if free(root)<reserve:
        raise ValueError('At least25GiB free required on the external build volume')
    derived=Path(tempfile.mkdtemp(prefix='derived-',dir=root))
    process=None
    try:
        process=subprocess.Popen([*command,'--derived-data',str(derived)],start_new_session=True)
        if started:started(process)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print('Test build timed out; stopping its process group',file=sys.stderr)
            return 124
    finally:
        # Also after an ordinary exit: whatever the build left running in its own group (its heavy-lock wrapper,
        # a compiler) ends before the folder under it goes, so no compiler keeps the shared lock or writes there.
        if process is not None:stop_group(process,grace)
        shutil.rmtree(derived,ignore_errors=True)


if __name__=='__main__':
    if len(sys.argv)==3 and sys.argv[1]=='--preflight':
        try:
            preflight(sys.argv[2])
        except (ValueError,OSError) as error:
            print(str(error),file=sys.stderr)
            raise SystemExit(2)
        raise SystemExit(0)
    if len(sys.argv)<3:
        raise SystemExit(__doc__)
    try:
        raise SystemExit(build(sys.argv[1],sys.argv[2:]))
    except (ValueError,OSError) as error:
        print(str(error),file=sys.stderr)
        raise SystemExit(2)
