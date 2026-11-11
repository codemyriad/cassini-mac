#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast subprocess proofs for real-worker harness ordering and assertions."""
import importlib.util
from pathlib import Path
import json
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('whistle_worker_test', Path(__file__).with_name('test-whistle-worker.py'))
worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)

FAKE = r'''
import json,os,sys
from pathlib import Path
log=Path(sys.argv[1]);mode=sys.argv[2]
previous=log.read_text().splitlines() if log.exists() else []
number=1+sum(json.loads(line)['kind']=='start' for line in previous)
def record(kind,**values):
 with log.open('a') as stream:stream.write(json.dumps(dict(kind=kind,child=number,**values))+'\n')
def emit(value):
 try:
  sys.stdout.write(json.dumps(value)+'\n');sys.stdout.flush()
 except BrokenPipeError:os._exit(0 if mode=='closed-zero' else 78)
record('start')
fd=int(os.environ['CASSINI_TEST_ENGINE_READY_FD'])
if mode in ['reject','early-ready-reject']:
 if mode=='early-ready-reject':os.write(fd,bytes([1]))
 os.close(fd);emit(dict(error='rejected'));sys.exit(78)
record('ready')
if mode!='missing-ready':os.write(fd,b'0' if mode=='bad-ready' else bytes([1]))
os.close(fd)
for line in sys.stdin.buffer:
 if len(line)>999999:
  record('oversize')
  emit(dict(error='tooLarge'));sys.exit(0 if mode=='oversize-zero' else 78)
 request=json.loads(line);identity=request['id'];record('request',id=identity)
 valid=Path(request['wav']).name=='jfk.wav'
 if not valid and mode!='accept-invalid':emit(dict(id=identity,error='invalidWav'));continue
 if identity=='input-3' and mode=='no-recovery':emit(dict(id=identity,error='invalidWav'));continue
 text='Changed.' if identity=='1' and mode=='different-repeat' else 'An English fixture.'
 emit(dict(id='stale' if mode=='stale-request' else identity,transcript=dict(text=text)))
if mode=='extra-response':emit(dict(id='unexpected'))
sys.exit(78 if mode=='bad-eof' else 0)
'''

class WorkerEvents(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(prefix='cassini-worker-events-')
        self.root=Path(self.directory.name);self.log=self.root/'events.jsonl'
        self.fake=self.root/'fake.py';self.fake.write_text(FAKE)
        (self.root/'jfk.wav').write_bytes(b'synthetic fixture; no audio decoding')
    def tearDown(self):self.directory.cleanup()
    def command(self,mode='good'):return [sys.executable,str(self.fake),str(self.log),mode]
    def test_fatal_probes_wait_for_correlated_startup_and_invalid_inputs_reuse_one_child(self):
        self.assertEqual(worker.exercise_requests(self.command(),self.root),'An English fixture.')
        rows=[json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([r['child'] for r in rows if r['kind']=='start'],[1,2,3])
        self.assertEqual([r['id'] for r in rows if r['child']==1 and r['kind']=='request'],['0','1','input-0','input-1','input-2','input-3'])
        self.assertEqual([r['id'] for r in rows if r['child']==3 and r['kind']=='request'],['0'])
        self.assertEqual([r['child'] for r in rows if r['kind']=='ready'],[1,2,3])
    def test_missing_or_invalid_engine_ready_event_is_rejected(self):
        for mode,error in [('missing-ready',EOFError),('bad-ready',ValueError)]:
            with self.subTest(mode=mode),self.assertRaises(error):
                worker.exercise_requests(self.command(mode),self.root)
    def test_rejected_invocation_cannot_announce_an_initialized_engine(self):
        result=worker.fails_before_ready(self.command('reject'),worker.worker_env())
        self.assertEqual(result.returncode,78)
        with self.assertRaises(AssertionError):
            worker.fails_before_ready(self.command('early-ready-reject'),worker.worker_env())
    def test_bad_input_repeated_transcript_recovery_eof_and_closed_output_assertions_are_preserved(self):
        for mode in ['accept-invalid','different-repeat','no-recovery','bad-eof','extra-response','closed-zero','stale-request','oversize-zero']:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                with self.assertRaises(AssertionError):worker.exercise_requests(self.command(mode),self.root)

if __name__=='__main__':unittest.main()
