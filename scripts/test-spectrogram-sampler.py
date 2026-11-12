#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Actual owned-child shutdown, independent of GUI, devices and elapsed time."""
import importlib.util
from pathlib import Path
import select
import signal
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('spectrogram_app', Path(__file__).with_name('test-spectrogram-app.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SamplerStopTests(unittest.TestCase):
    def child(self, ignore_term):
        handler = 'signal.SIG_IGN' if ignore_term else 'lambda *_: sys.exit(0)'
        code = f'import signal,sys; signal.signal(signal.SIGTERM,{handler}); print("ready",flush=True); sys.stdin.buffer.read(1)'
        process = subprocess.Popen([sys.executable, '-u', '-c', code], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(self.cleanup, process)
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Child did not register its signal handler')
        self.assertEqual(process.stdout.readline(), b'ready\n')
        return process

    @staticmethod
    def cleanup(process):
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        process.stdin.close()
        process.stdout.close()

    def test_ignoring_sampler_is_reaped(self):
        process = self.child(True)
        module.stop_sampler(process)
        self.assertEqual(process.returncode, -signal.SIGKILL)

    def test_signal_choice_is_explicit_for_a_cooperative_sampler(self):
        process = self.child(False)
        module.stop_sampler(process)
        self.assertEqual(process.returncode, -signal.SIGKILL, 'Diagnostic cleanup must not depend on a graceful signal handler')

    def test_already_exited_sampler_retains_its_result(self):
        process = subprocess.Popen([sys.executable, '-c', 'pass'])
        self.addCleanup(lambda: process.poll() is None and process.kill())
        process.wait(timeout=5)
        module.stop_sampler(process)
        self.assertEqual(process.returncode, 0)


if __name__ == '__main__':
    unittest.main()
