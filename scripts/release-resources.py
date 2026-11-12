#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Resource admission inside the shared lock; never waits or reads signing keys."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def admit(extra_gib,free_bytes,pressure):
    if free_bytes < (10+extra_gib)*1024**3:
        raise ValueError('Insufficient disk reserve for test release')
    match=re.search(r'System-wide memory free percentage: (\d+)%',pressure)
    if not match or int(match.group(1)) < 20:
        raise ValueError('Memory pressure prevents test release')


if __name__=='__main__':
    if os.environ.get('CASSINI_HEAVY_LOCK_HELD')!='1':
        raise SystemExit('Release resources must be checked under the shared lock')
    pressure=subprocess.check_output(['memory_pressure'],text=True)
    stats=subprocess.check_output(['vm_stat'],text=True)
    before=os.environ.get('CASSINI_RELEASE_SWAPOUTS')
    current=re.search(r'^Swapouts:\s+(\d+)',stats,re.M)
    if before is not None and (not current or int(current.group(1))>int(before)):
        raise SystemExit('Swap grew before test release; wait for memory recovery')
    admit(int(sys.argv[1]),shutil.disk_usage(Path(__file__).resolve().parent.parent).free,pressure)
    os.execvp(sys.argv[2],sys.argv[2:])
