#!/usr/bin/env python3
"""Inert child lifecycle checks, never product audio or UI."""
import importlib.util
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('runner',Path(__file__).with_name('run-swift-tests.py'))
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)

class TestRunner(unittest.TestCase):
    def test_exit_status_and_output_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            code=runner.run([sys.executable,'-c',"print('complete',flush=True);raise SystemExit(7)"],root,forward=False)
            self.assertEqual(code,7);self.assertEqual((root/'tests.log').read_text(),'complete\n')
    def test_stall_collects_live_child_diagnostics_then_reaps_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);observed=[]
            def diagnose(pid,folder):
                os.kill(pid,0);observed.append(pid)
                (folder/'proof.txt').write_text('sampled while alive')
            code=runner.run([sys.executable,'-c',"import signal;print('entered',flush=True);signal.pause()"],root,idle_seconds=0.1,diagnose=diagnose,forward=False)
            self.assertEqual(code,124);self.assertEqual(len(observed),1)
            with self.assertRaises(ProcessLookupError):os.kill(observed[0],0)
            self.assertEqual((root/'proof.txt').read_text(),'sampled while alive')
    def test_diagnostic_failure_still_reaps_the_owned_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def diagnose(*_):raise RuntimeError('sample unavailable')
            self.assertEqual(runner.run([sys.executable,'-c','import signal;signal.pause()'],root,idle_seconds=0.1,diagnose=diagnose,forward=False),124)
            self.assertIn('sample unavailable',(root/'diagnostic-error.txt').read_text())
if __name__=='__main__':unittest.main()
