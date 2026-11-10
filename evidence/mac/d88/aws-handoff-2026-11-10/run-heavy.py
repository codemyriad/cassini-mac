"""Serialize local Mac test/build work with the shared AWS mkdir lock."""
import fcntl
import os
import signal
import subprocess
import sys
import time


def interrupted(number, _frame):
    raise SystemExit(128 + number)


signal.signal(signal.SIGTERM, interrupted)
lock_directory = os.path.expanduser('~/.aws-heavy.lock')
with open(os.path.expanduser('~/.cassini-heavy.lock'), 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    acquired = False
    try:
        while not acquired:
            try:
                os.mkdir(lock_directory)
                acquired = True
            except FileExistsError:
                time.sleep(2)
        env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode_16.4.app/Contents/Developer')
        result = subprocess.call(sys.argv[1:], env=env)
    finally:
        if acquired:
            os.rmdir(lock_directory)
    sys.exit(result)
