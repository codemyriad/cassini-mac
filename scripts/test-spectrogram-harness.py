#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""File-only tests of the hosted motion driver's correlated completion relay."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('spectro_harness',Path(__file__).with_name('test-spectrogram-app.py'))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

class MotionCompletion(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.request = Path(self.temporary.name)/'motion-request.json'
        self.ack = self.request.with_name('motion-ack.json')
        self.request.write_text(json.dumps({'requestID':'first','reduceMotion':True}))

    def emit(self,value):
        return harness.relay_motion_ack('CASSINI_SPECTRO_MOTION_ACK:'+json.dumps(value)+'\n',self.request)

    def test_only_current_completion_creates_an_acknowledgement(self):
        self.assertFalse(self.emit({'requestID':'old'}))
        self.assertFalse(self.ack.exists())
        self.assertTrue(self.emit({'requestID':'first'}))
        self.assertEqual(json.loads(self.ack.read_text()),{'requestID':'first'})
        self.assertFalse(self.ack.with_name('.motion-ack.tmp').exists())

    def test_prior_success_cannot_complete_the_next_os_transition(self):
        self.assertTrue(self.emit({'requestID':'first'}))
        self.request.write_text(json.dumps({'requestID':'second','reduceMotion':False}))
        self.assertFalse(self.emit({'requestID':'first'}))
        self.assertEqual(json.loads(self.ack.read_text())['requestID'],'first')
        self.assertTrue(self.emit({'requestID':'second'}))
        self.assertEqual(json.loads(self.ack.read_text())['requestID'],'second')

    def test_normal_logs_and_malformed_markers_do_not_acknowledge(self):
        for line in ['Test Case passed','CASSINI_SPECTRO_MOTION_ACK:no json',
                     'CASSINI_SPECTRO_MOTION_ACK:[]','CASSINI_SPECTRO_MOTION_ACK:{}']:
            self.assertFalse(harness.relay_motion_ack(line,self.request))
        for value in ['',None,1,[],{}]:
            self.assertFalse(self.emit({'requestID':value}))
        self.assertFalse(self.ack.exists())

    def test_log_prefix_does_not_hide_the_real_completion(self):
        self.assertTrue(harness.relay_motion_ack('runner stdout: CASSINI_SPECTRO_MOTION_ACK:{"requestID":"first"}\n',self.request))
        self.assertEqual(json.loads(self.ack.read_text())['requestID'],'first')

    def test_missing_request_cannot_be_acknowledged(self):
        self.request.unlink()
        self.assertFalse(self.emit({'requestID':'first'}))
        self.assertFalse(self.ack.exists())

if __name__ == '__main__':
    unittest.main()
