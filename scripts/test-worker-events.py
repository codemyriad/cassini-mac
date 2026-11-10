#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Device-free tests of real Darwin process/pipe events and failure handling."""
import os
import select
import subprocess
import sys
import unittest
from unittest.mock import Mock
from worker_events import ProcessExit, json_line, watchdog_ticks, discard_ticks


class WorkerEvents(unittest.TestCase):
    def pipe(self):
        read, write = os.pipe()
        self.addCleanup(os.close, read); self.addCleanup(os.close, write)
        return read, write

    def test_json_response_is_complete_and_bounded(self):
        read, write = self.pipe()
        os.write(write, b'{"child":123}\n')
        with os.fdopen(os.dup(read), 'rb', buffering=0) as stream:
            self.assertEqual(json_line(stream), {'child': 123})
        os.write(write, b'x'*8)
        with os.fdopen(os.dup(read), 'rb', buffering=0) as stream:
            with self.assertRaises(ValueError): json_line(stream, maximum=8)

    def test_closed_pipe_cannot_substitute_for_a_worker_response(self):
        read, write = os.pipe(); os.close(write)
        with os.fdopen(read, 'rb', buffering=0) as stream:
            with self.assertRaises(EOFError): json_line(stream)

    def test_only_actual_tick_tokens_satisfy_callback_progress(self):
        read, write = self.pipe()
        os.write(write, b'\x01\x01'); watchdog_ticks(read)
        os.write(write, b'\x01'); discard_ticks(read)
        self.assertEqual(select.select([read], [], [], 0)[0], [])
        os.write(write, b'bad')
        with self.assertRaises(ValueError): watchdog_ticks(read)

    def test_kernel_exit_after_registration_is_the_completion(self):
        child = subprocess.Popen([sys.executable, '-c', 'import sys;sys.stdin.buffer.read(1)'], stdin=subprocess.PIPE)
        try:
            with ProcessExit(child.pid) as exit_event:
                child.stdin.write(b'1'); child.stdin.flush()
                exit_event.wait()
            self.assertEqual(child.wait(timeout=10), 0)
        finally:
            if child.poll() is None: child.kill(); child.wait(timeout=10)
            child.stdin.close()

    def test_empty_or_wrong_kernel_event_cannot_pass(self):
        # A manual missing-event result tests the guard without waiting a deadline.
        watched = ProcessExit.__new__(ProcessExit); watched.pid = os.getpid(); watched.queue = Mock()
        watched.queue.control.return_value = []
        with self.assertRaises(TimeoutError): watched.wait()
        watched.queue.control.return_value = [select.kevent(os.getpid()+1, filter=select.KQ_FILTER_PROC, fflags=select.KQ_NOTE_EXIT)]
        with self.assertRaises(RuntimeError): watched.wait()


if __name__ == '__main__': unittest.main()
