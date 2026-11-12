#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run under heavy-run in a disposable checkout; modifies only the card source."""
from pathlib import Path
import argparse
import json
import subprocess
import sys

area=Path(__file__).resolve().parent
root=area.parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',required=True,type=Path)
parser.add_argument('--tokens-ref',default='c2f77c119671fb7c643f5ee024f245f23269e122')
parser.add_argument('--baseline-ref',default='72d3704b')
args=parser.parse_args()
output=args.output.expanduser().resolve()
if output==root or root in output.parents:parser.error('Keep output outside checkout')
output.mkdir(parents=True,exist_ok=True)
source=root/'Components/MeetingCard/MeetingCard.swift'
original=source.read_bytes()
command=[sys.executable,str(root/'scripts/render-meeting-cards.py'),
         '--tokens-ref',args.tokens_ref,'--baseline-ref',args.baseline_ref]

def run(name):
    result=subprocess.run(command+['--output',str(output/name)],cwd=root,
                          capture_output=True,text=True,timeout=180)
    (output/(name+'.log')).write_text(result.stdout+result.stderr)
    return result

baseline=run('baseline')
assert baseline.returncode==0,baseline.stderr
results={}
try:
    for case in json.loads((area/'cases.json').read_text()):
        patch=area/(case['name']+'.patch')
        subprocess.run(['git','apply','--check',str(patch)],cwd=root,check=True)
        subprocess.run(['git','apply',str(patch)],cwd=root,check=True)
        result=run(case['name'])
        assert result.returncode==1 and 'Card proof failed:' in result.stderr and case['expectedFailure'] in result.stderr,result.stderr
        results[case['name']]={'exitCode':result.returncode,'expectedFailure':case['expectedFailure']}
        source.write_bytes(original)
finally:source.write_bytes(original)
restored=run('restored')
assert restored.returncode==0,restored.stderr
assert source.read_bytes()==original
(output/'mutations.json').write_text(json.dumps(results,indent=2)+'\n')
print('Eight production mutations fail native assertions; restored four card states pass')
