#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run one release build with its DerivedData on an external volume.

    external-derived-build.py ROOT COMMAND [ARG...]

Started by the test-release scheduler through the logged-in (Aqua) session's runner, because a LaunchAgent has no
access to removable volumes. Makes a private folder under ROOT, appends `--derived-data FOLDER` to COMMAND, waits for
it and removes the folder again, whatever the outcome. The scheduler itself never touches ROOT.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

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


def build(root,command,reserve=RESERVE,timeout=TIMEOUT,free=lambda path:shutil.disk_usage(path).free):
    root=external_root(root)
    if free(root)<reserve:
        raise ValueError('At least25GiB free required on the external build volume')
    derived=Path(tempfile.mkdtemp(prefix='derived-',dir=root))
    try:
        process=subprocess.Popen([*command,'--derived-data',str(derived)],start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Only this build's process group, with its heavy-lock wrapper: no compiler keeps the shared lock.
            os.killpg(process.pid,signal.SIGTERM)
            try:process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait()
            print('Test build timed out; own process group stopped',file=sys.stderr)
            return 124
    finally:
        shutil.rmtree(derived,ignore_errors=True)


if __name__=='__main__':
    if len(sys.argv)<3:
        raise SystemExit(__doc__)
    try:
        raise SystemExit(build(sys.argv[1],sys.argv[2:]))
    except ValueError as error:
        print(str(error),file=sys.stderr)
        raise SystemExit(2)
