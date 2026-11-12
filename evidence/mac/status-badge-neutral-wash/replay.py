#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run under heavy-run in a disposable checkout; modifies only the badge source."""
from pathlib import Path
import argparse
import json
import subprocess
import sys

area=Path(__file__).resolve().parent
root=area.parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args()
output=args.output.expanduser().resolve()
if output==root or root in output.parents:parser.error('Keep output outside checkout')
output.mkdir(parents=True,exist_ok=True)
source=root/'Components/StatusBadge/MeetingStatusBadge.swift'
original=source.read_bytes()
command=[sys.executable,str(root/'scripts/render-status-badge-wash.py')]

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
        assert result.returncode==1 and 'Badge proof failed:' in result.stderr and case['expectedFailure'] in result.stderr,result.stderr
        results[case['name']]={'exitCode':result.returncode,'expectedFailure':case['expectedFailure']}
        source.write_bytes(original)
finally:source.write_bytes(original)
restored=run('restored')
assert restored.returncode==0,restored.stderr
assert source.read_bytes()==original
(output/'mutations.json').write_text(json.dumps(results,indent=2)+'\n')
print('Four production mutations fail native assertions; restored 42 cases pass')
