#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run a CI shell under the iOS host flock, releasing only after its children exit.

Hosted runners pass through. The lock inode is retained (also used by iOS
scripts/test-events.py), so waiting jobs cannot acquire different inodes.
"""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys


def run(command):
    if os.environ.get('RUNNER_ENVIRONMENT') != 'self-hosted' or os.environ.get('CASSINI_HEAVY_LOCK_HELD') == '1':
        os.execvp(command[0], command)
    # The GUI account shares the fleet host with /Users/m1's iOS/headless
    # runners. Use their inode too, matching gui-runner/xcodebuild's root.
    root = Path(os.environ.get('CASSINI_HEAVY_LOCK_ROOT',
                               '/Users/m1' if Path('/Users/m1').is_dir() else str(Path.home())))
    lock = Path(os.environ.get('CASSINI_HEAVY_LOCK', str(root/'.cassini-heavy.lock')))
    process = None

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    def timed_out(_signum, _frame):
        raise TimeoutError('Timed out waiting for host heavy lock: ' + str(lock))

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        handle = lock.open('a+')
    except PermissionError:
        # flock permits exclusive locks on a read-only descriptor. A standard
        # GUI account can coordinate on the owner's 0644 file without changing it.
        handle = lock.open('r')
    with handle:
        signal.signal(signal.SIGALRM, timed_out)
        print('Waiting for shared iOS/Mac host lock: ' + str(lock), flush=True)
        signal.alarm(int(os.environ.get('CASSINI_CI_LOCK_SECONDS', '600')))
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
        finally:
            signal.alarm(0)
        try:
            if handle.writable():
                handle.seek(0); handle.truncate()
                handle.write('cassini-mac CI ' + os.environ.get('GITHUB_RUN_ID', 'local') + '\n'); handle.flush()
            process = subprocess.Popen(command, start_new_session=True,
                                       env=dict(os.environ, CASSINI_HEAVY_LOCK_HELD='1'))
            return process.wait()
        finally:
            # Cancellation must not free the lock while an owned compiler/test
            # child is still running, or kill another runner's processes.
            if process is not None:
                for sig in (signal.SIGINT, signal.SIGTERM):
                    signal.signal(sig, signal.SIG_IGN)
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: pass
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            if handle.writable():
                handle.seek(0); handle.truncate()


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('usage: ci-heavy.py command [args...]')
    sys.exit(run(sys.argv[1:]))
