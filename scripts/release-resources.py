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


def storage(arguments):
    """Splits `[--reserve GIB PATH]... COMMAND...` or the older `GIB COMMAND...` (on this checkout's disk) into the
    reserves, each (extra GiB, path), and the command."""
    reserves=[]
    while arguments[:1]==['--reserve']:
        if len(arguments)<3:raise ValueError('--reserve takes a size in GiB and a path')
        reserves.append((int(arguments[1]),Path(arguments[2])));arguments=arguments[3:]
    if not reserves:
        reserves=[(int(arguments[0]),Path(__file__).resolve().parent.parent)];arguments=arguments[1:]
    if not arguments:raise ValueError('No command to run')
    return reserves,arguments


def existing(path):
    """The nearest folder that exists: a build folder that is still to be made is measured on its parent's disk."""
    path=Path(path)
    while not path.exists() and path!=path.parent:path=path.parent
    return path


def admit_all(reserves,pressure,free=lambda path:shutil.disk_usage(path).free):
    for extra,path in reserves:admit(extra,free(existing(path)),pressure)


if __name__=='__main__':
    if os.environ.get('CASSINI_HEAVY_LOCK_HELD')!='1':
        raise SystemExit('Release resources must be checked under the shared lock')
    pressure=subprocess.check_output(['memory_pressure'],text=True)
    stats=subprocess.check_output(['vm_stat'],text=True)
    before=os.environ.get('CASSINI_RELEASE_SWAPOUTS')
    current=re.search(r'^Swapouts:\s+(\d+)',stats,re.M)
    if before is not None and (not current or int(current.group(1))>int(before)):
        raise SystemExit('Swap grew before test release; wait for memory recovery')
    try:
        reserves,program=storage(sys.argv[1:])
        admit_all(reserves,pressure)
    except ValueError as error:raise SystemExit(str(error))
    os.execvp(program[0],program)
