#!/usr/bin/env python3
"""Behavioral checks for cross-repo exclusion and cancellation, using process events."""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class HostLock(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.lock = Path(self.temp.name)/'host.lock'
        self.env = dict(os.environ, RUNNER_ENVIRONMENT='self-hosted',
                        CASSINI_HEAVY_LOCK=str(self.lock), CASSINI_HEAVY_LOCK_HELD='')

    def start(self, code, **overrides):
        process = subprocess.Popen([sys.executable, str(ROOT/'scripts/ci-heavy.py'), sys.executable, '-u', '-c', code],
                                   env=dict(self.env, **overrides), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, process)
        return process

    def stop(self, process):
        if process.poll() is None: process.terminate()
        process.communicate(timeout=10)
        for stream in [process.stdin, process.stdout, process.stderr]: stream.close()

    def test_shell_holds_ios_flock_until_exit_and_keeps_inode(self):
        process = self.start('import os,sys; print(os.environ["CASSINI_HEAVY_LOCK_HELD"]); sys.stdin.readline(); sys.exit(37)')
        self.assertIn('Waiting for shared', process.stdout.readline())
        self.assertEqual(process.stdout.readline().strip(), '1')
        with self.lock.open('a+') as probe:
            inode = os.fstat(probe.fileno()).st_ino
            with self.assertRaises(BlockingIOError): fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process.stdin.write('finish\n'); process.stdin.flush()
            self.assertEqual(process.wait(timeout=10), 37)
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.lock.stat().st_ino, inode)
            self.assertEqual(self.lock.read_text(), '')

    def test_waiting_cancellation_does_not_change_another_holders_note(self):
        with self.lock.open('w+') as owner:
            fcntl.flock(owner, fcntl.LOCK_EX)
            owner.write('iOS owner\n'); owner.flush()
            process = self.start('raise AssertionError("must not run while iOS owns lock")')
            self.assertIn('Waiting for shared', process.stdout.readline())
            process.terminate()
            self.assertEqual(process.wait(timeout=10), 128 + signal.SIGTERM)
            self.assertEqual(self.lock.read_text(), 'iOS owner\n')

    def test_cancellation_stops_owned_shell_before_unlock(self):
        process = self.start('import os,sys; print(os.getpid()); sys.stdin.readline()')
        process.stdout.readline()
        child = int(process.stdout.readline())
        process.terminate(); process.wait(timeout=10)
        with self.assertRaises(ProcessLookupError): os.kill(child, 0)
        with self.lock.open('a+') as probe:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_hosted_and_nested_shells_pass_through_without_second_lock(self):
        for overrides in [dict(RUNNER_ENVIRONMENT='github-hosted'), dict(CASSINI_HEAVY_LOCK_HELD='1')]:
            process = self.start('print("passed"); raise SystemExit(23)', **overrides)
            self.assertEqual(process.stdout.readline().strip(), 'passed')
            self.assertEqual(process.wait(timeout=10), 23)
            self.assertFalse(self.lock.exists())


if __name__ == '__main__': unittest.main()
