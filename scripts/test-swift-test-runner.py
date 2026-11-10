#!/usr/bin/env python3
"""Inert child lifecycle checks, never product audio or UI."""
import importlib.util
from pathlib import Path
import os
import sys
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('runner',Path(__file__).with_name('run-swift-tests.py'))
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)

class ManualIdle:
    def __init__(self):
        self.now = 0
        self.saw_output = False

    def clock(self):
        return self.now

    def wait(self, selector, remaining):
        if not self.saw_output:
            ready = selector.select(10)
            if not ready:
                raise AssertionError('fixture did not publish its entry line')
            self.saw_output = True
            return ready
        if remaining <= 0:
            raise AssertionError('runner waited again at the expired deadline')
        self.now += remaining
        return []


class TestRunner(unittest.TestCase):
    def test_exit_status_and_output_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            code=runner.run([sys.executable,'-c',"print('complete',flush=True);raise SystemExit(7)"],root,forward=False)
            self.assertEqual(code,7);self.assertEqual((root/'tests.log').read_text(),'complete\n')
    def run_stalled_child(self, root, diagnose):
        idle = ManualIdle()
        command = [sys.executable,'-c',"import signal;print('entered',flush=True);signal.pause()"]
        code = runner.run(command,root,diagnose=diagnose,forward=False,
                          clock=idle.clock,wait_for_output=idle.wait)
        self.assertEqual(code,124)
        self.assertEqual((root/'tests.log').read_text(),'entered\n')

    def test_stall_collects_live_child_diagnostics_then_reaps_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);observed=[]
            def diagnose(pid,folder):
                os.kill(pid,0);observed.append(pid)
                (folder/'proof.txt').write_text('sampled while alive')
            self.run_stalled_child(root,diagnose)
            self.assertEqual(len(observed),1)
            with self.assertRaises(ProcessLookupError):os.kill(observed[0],0)
            self.assertEqual((root/'proof.txt').read_text(),'sampled while alive')

    def test_diagnostic_failure_still_reaps_the_owned_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);observed=[]
            def diagnose(pid,_):
                os.kill(pid,0);observed.append(pid)
                raise RuntimeError('sample unavailable')
            self.run_stalled_child(root,diagnose)
            self.assertEqual(len(observed),1)
            with self.assertRaises(ProcessLookupError):os.kill(observed[0],0)
            self.assertIn('sample unavailable',(root/'diagnostic-error.txt').read_text())
if __name__=='__main__':unittest.main()
