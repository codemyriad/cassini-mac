#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast subprocess proofs for real-worker harness ordering and assertions."""
import importlib.util
from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

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
record('start');armed=False
for line in sys.stdin.buffer:
 if len(line)>999999:
  record('oversize',armed=armed)
  emit(dict(error='tooLarge'));sys.exit(78 if armed else 77)
 request=json.loads(line);identity=request['id'];record('request',id=identity)
 if number>1 and not armed and identity!='startup-barrier':sys.exit(77)
 if identity=='startup-barrier':
  armed=True;emit(dict(id='stale' if mode=='stale-barrier' else identity,error='invalidMeeting'));continue
 valid=Path(request['wav']).name=='jfk.wav'
 if not valid and mode!='accept-invalid':emit(dict(id=identity,error='invalidWav'));continue
 if identity=='input-3' and mode=='no-recovery':emit(dict(id=identity,error='invalidWav'));continue
 text='Changed.' if identity=='1' and mode=='different-repeat' else 'An English fixture.'
 emit(dict(id=identity,transcript=dict(text=text)))
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
        self.assertEqual([r['id'] for r in rows if r['child']==3 and r['kind']=='request'],['startup-barrier','0'])
        self.assertEqual([r['armed'] for r in rows if r['kind']=='oversize'],[True])
    def test_removing_the_startup_barrier_is_rejected(self):
        with patch.object(worker,'acknowledge_startup',lambda child:None),self.assertRaises(AssertionError):
            worker.exercise_requests(self.command(),self.root)
    def test_bad_input_repeated_transcript_recovery_eof_and_closed_output_assertions_are_preserved(self):
        for mode in ['accept-invalid','different-repeat','no-recovery','bad-eof','extra-response','closed-zero','stale-barrier']:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                with self.assertRaises(AssertionError):worker.exercise_requests(self.command(mode),self.root)

if __name__=='__main__':unittest.main()
