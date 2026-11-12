#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run under heavy-run in a disposable checkout; restore every mutated source."""
from pathlib import Path
import argparse
import json
import subprocess
import sys

area=Path(__file__).resolve().parent;root=area.parents[2]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args();output=args.output.expanduser().resolve()
if output==root or root in output.parents:parser.error('Keep output outside checkout')
output.mkdir(parents=True,exist_ok=True)
cases=json.loads((area/'cases.json').read_text())
original={case['source']:(root/case['source']).read_bytes() for case in cases}
command=[sys.executable,str(root/'scripts/render-badge-labels.py')]
def run(name):
    result=subprocess.run(command+['--output',str(output/name)],cwd=root,capture_output=True,text=True,timeout=180)
    (output/(name+'.log')).write_text(result.stdout+result.stderr);return result
baseline=run('baseline');assert baseline.returncode==0,baseline.stderr
results={}
try:
    for case in cases:
        patch=area/(case['name']+'.patch')
        subprocess.run(['git','apply','--check',str(patch)],cwd=root,check=True)
        subprocess.run(['git','apply',str(patch)],cwd=root,check=True)
        result=run(case['name'])
        assert result.returncode==1 and 'Badge label proof failed:' in result.stderr and case['expectedFailure'] in result.stderr,result.stderr
        results[case['name']]={'exitCode':result.returncode,'expectedFailure':case['expectedFailure']}
        for path,data in original.items():(root/path).write_bytes(data)
finally:
    for path,data in original.items():(root/path).write_bytes(data)
restored=run('restored');assert restored.returncode==0,restored.stderr
assert all((root/path).read_bytes()==data for path,data in original.items())
(output/'mutations.json').write_text(json.dumps(results,indent=2)+'\n')
print('Nine production mutations fail native assertions; restored W2.2 proof passes')
