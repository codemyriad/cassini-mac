#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted attribution only. Ablated variants are incomplete, never product proof."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('Disposable GitHub-hosted Mac required')
program=Path(sys.argv[1]).resolve()
output=Path(sys.argv[2]);output.mkdir(parents=True,exist_ok=True)
reports=[]
original=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
source=Path(__file__).resolve().parent.parent/'Cassini/Recording/RecordingSpectrogram.swift'
try:
    subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
    for case in 'AD':
        for variant in ['full','no-contents','no-scroll','none']:
            name=case+'-'+variant
            folder=output/name;folder.mkdir()
            command=[str(program),'--spectrogram-self-test','-SpectrogramCase',case,
                     '-SpectrogramOutput',str(folder.resolve()),'-ApplePersistenceIgnoreState','YES']
            env=dict(os.environ,CASSINI_SPECTRO_ABLATION=variant,CASSINI_SPECTRO='1')
            with (output/(name+'.stderr')).open('w') as stderr:
                completed=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=stderr,text=True,timeout=100)
            (output/(name+'.stdout')).write_text(completed.stdout)
            report=json.loads(completed.stdout)
            report.update(ablation=variant,diagnosticOnly=True,exitStatus=completed.returncode,
                          rendererSHA256=hashlib.sha256(source.read_bytes()).hexdigest())
            reports.append(report)
            (output/(name+'.json')).write_text(json.dumps(report,indent=2)+'\n')
            print(case,variant,'main',report.get('drawingCorePercent'),'region',report.get('instrumentedDrawingCorePercent'),
                  'analysis',report.get('analysisCorePercent'),'gates',report.get('gates'),flush=True)
finally:
    command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if original.stdout.strip()=='1' else 'false'] if original.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
    subprocess.run(command,capture_output=True)
    (output/'summary.json').write_text(json.dumps({'scope':'Attribution only. no-contents, no-scroll and none deliberately suppress rendering work and are NOT correctness/performance acceptance candidates. Original full variant gates remain unchanged. All variants use identical native sinks, clocks and same-build production SDK. No local native execution.', 'measurements':reports},indent=2)+'\n')
if any(r['exitStatus'] for r in reports) or any(not all(r.get('gates',{}).values()) for r in reports if r['ablation']=='full'):
    raise SystemExit('Production full-variant gates still fail; see attribution reports')
