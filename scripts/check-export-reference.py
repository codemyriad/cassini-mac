#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check generated files with the pinned independent pure format tools."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

PIN = '867f68c56292ada9464b8516dc2797003d5af9eb'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference',type=Path)
parser.add_argument('cases',type=Path)
parser.add_argument('--stereo-source',type=Path,default=Path(__file__).resolve().parent.parent/'Tests/CassiniExportTests/Fixtures/stereo-tone.opus')
args = parser.parse_args()
assert subprocess.check_output(['git','-C',str(args.reference),'rev-parse','HEAD'],text=True).strip() == PIN
subprocess.run(['git','-C',str(args.reference),'diff','--quiet','HEAD','--','tools/cassini-read-pure.py','tools/cassini-opus-digest.py'],check=True)

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);sys.modules[name]=value;spec.loader.exec_module(value);return value

metadata=module('cassini_reference_metadata',args.reference/'tools/cassini-read-pure.py')
audio=module('cassini_reference_audio',args.reference/'tools/cassini-opus-digest.py')
stereo=audio.compute(str(args.stereo_source))
# Expectations follow the test INPUTS, not the writer's self-reported output.
expected={'stereo':(2,48000,0),'opaque-x':(2,48000,0),
          'pcm-8000':(1,30000,0),'pcm-16000':(1,30000,0),'pcm-48000':(1,30000,0),
          'words-running':(1,48000,0),'words-failed':(1,48000,0),'words-done':(1,48000,1),
          'stale-checkpoint':(1,48000,0)}
assert {p.stem for p in args.cases.glob('*.opus')} == set(expected), 'Missing/unexpected generated cases'
reports=[]
for name,(channels,samples,words) in expected.items():
    path=args.cases/(name+'.opus')
    read,_=metadata.read_file(str(path));dig=audio.compute(str(path))
    assert read['state']=='unverified' and isinstance(read['words'],list), (name,read)
    assert len(read['words'])==words,(name,read['words'])
    manifest=read['manifest'];shape=manifest['audio'];integ=manifest['integrity']
    assert dig['channels']==channels and dig['sampleCount']==samples,(name,dig)
    for key,value in [('sampleRate',48000),('channels',channels),('sampleCount',samples),('durationMs',samples*1000//48000)]:
        assert shape[key]==value and integ[key]==value,(name,key,shape,integ)
    assert integ['opusAudioSha256']==dig['sha256'] and integ['matchPolicy']=='exact-opus-audio-v1'
    assert len(manifest['transcripts'])==1 and manifest['transcripts'][0]['wordCount']==words
    if name in ('stereo','opaque-x'):assert dig['sha256']==stereo['sha256'],(name,dig,stereo)
    if name=='stereo':assert [n['atMs'] for n in manifest['x']['gocassini.com']['notes']]==[120,10]
    if name=='opaque-x':assert manifest['x']['other.example']['integer']==9007199254740993
    if name!='words-done':assert not manifest.get('readableTranscripts') and not manifest.get('provenance',{}).get('speechToText')
    reports.append(dict(name=name,channels=channels,sampleCount=samples,words=words,sha256=dig['sha256']))
(args.cases/'reference-report.json').write_text(json.dumps(dict(reference=PIN,cases=reports),indent=2)+'\n')
print('PASS',len(reports),'exports: independent pure metadata + audio readers')
